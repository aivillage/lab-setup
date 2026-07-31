# ═══════════════════════════════════════════════════════════════════
# talos/config.nix
#
# Three concerns, cleanly separated:
#   mkMachinePatch     — per-machine YAML patch (hostname, network, disk)
#   mkMachineConfig    — generates one machine's talos config from a
#                        patches directory (no baked-in patch list)
#   mkGeneratePatches  — builds cilium, nvidia, nfs, and model-store
#                        patches from lab parameters and writes them
#                        to a directory
#
{
  pkgs,
  lib,
  inputs ? { },
}:

let
  kubelib =
    if inputs ? nix-kube-generators then
      inputs.nix-kube-generators.lib { inherit pkgs; }
    else if
      inputs ? lab-setup && inputs.lab-setup ? inputs && inputs.lab-setup.inputs ? nix-kube-generators
    then
      inputs.lab-setup.inputs.nix-kube-generators.lib { inherit pkgs; }
    else
      null;

  # ── Per-machine patch: hostname + network + install ───────────
  mkMachinePatch =
    { machine, schematic }:
    let
      installerImage = "factory.talos.dev/installer/${builtins.readFile schematic}:${machine.version}";
      ifaces = machine.network-interfaces or { };
      explicitPrimary = lib.filterAttrs (_name: iface: iface.primary or false) ifaces;
      primaryIfaceName =
        if explicitPrimary != { } then
          lib.head (lib.attrNames explicitPrimary)
        else if ifaces != { } then
          lib.head (lib.attrNames ifaces)
        else
          null;
      ifaceList =
        if primaryIfaceName != null then
          [
            {
              interface = primaryIfaceName;
              dhcp = true;
            }
          ]
        else
          [ ];
      patchObj = {
        machine = {
          network = {
            hostname = machine.name;
          } // (if ifaceList != [ ] then { interfaces = ifaceList; } else { });
          install = {
            image = installerImage;
            wipe = true;
            diskSelector = {
              size = ">= 400GB";
            };
          };
        };
      };
    in
    pkgs.writeText "${machine.name}-machine-patch.yaml" (builtins.toJSON patchObj);
  nvidiaPatch =
    if kubelib != null then import ./patches/nvidia.nix { inherit pkgs kubelib; } else null;
  # ── Generate a patches directory ──────────────────────────────
  #
  # Accepts lab-specific parameters (model store, optional NFS server/path)
  # and builds cilium, nvidia, and model-store patches internally.
  # Extra { name, file } patches can be appended via `extraPatches`.
  #
  mkGeneratePatches =
    {
      nfsServer ? "",
      nfsPath ? "/data",
      extraPatches ? [ ],
      modelStorePath ? "",
      webserverHost ? "http://10.211.0.10:8080/configs",
    }:
    let
      ciliumPatch =
        if kubelib != null then import ./patches/cilium.nix { inherit pkgs kubelib; } else null;
      ciliumLoaderPatch = import ./patches/cilium-loader.nix {
        inherit pkgs;
        host = webserverHost;
        ciliumPatchName = "cilium.yaml";
      };

      nvidiaPatches =
        if nvidiaPatch != null then
          [
            {
              name = "nvidia-helm.yaml";
              file = nvidiaPatch.helmPatch;
            }
            {
              name = "nvidia-runtime.yaml";
              file = nvidiaPatch.runtimeClassPatch;
            }
          ]
        else
          [ ];

      nfsPatch =
        if nfsServer != "" && kubelib != null then
          [
            {
              name = "nfs.yaml";
              file = import ./patches/nfs.nix {
                inherit pkgs kubelib;
                server = nfsServer;
                path = nfsPath;
              };
            }
          ]
        else
          [ ];

      patches = [
        {
          name = "cilium-loader.yaml";
          file = ciliumLoaderPatch;
        }
        {
          name = "schedule.yaml";
          file = ./patches/schedule.yaml;
        }
      ]
      ++ lib.optional (ciliumPatch != null) {
        name = "cilium.yaml";
        file = ciliumPatch;
      }
      ++ nvidiaPatches
      ++ nfsPatch
      ++ extraPatches;
    in
    pkgs.writeShellScriptBin "generate-patches" ''
      set -euo pipefail

      OUTPUT_DIR="''${1:-.talos/patches}"
      mkdir -p "$OUTPUT_DIR"

      echo "Generating shared patches → $OUTPUT_DIR"

      ${lib.concatMapStringsSep "\n" (p: ''
        cp -f ${p.file} "$OUTPUT_DIR/${p.name}"
      '') patches}

      echo "✅ ${toString (builtins.length patches)} patches written to $OUTPUT_DIR"
    '';

  # ── Generate a single machine's config ────────────────────────
  mkMachineConfig =
    {
      machine,
      clusterName,
      clusterEndpoint,
      talosVersion,
      schematic,
    }:
    let
      machinePatch = mkMachinePatch { inherit machine schematic; };
      outputType = if machine.controlPlane then "controlplane" else "worker";
    in
    pkgs.writeShellScriptBin "generate-config" ''
      set -euo pipefail

      PATCHES_DIR="''${1:?Usage: generate-config <patches-dir> [secrets-file]}"
      SECRETS_FILE="''${2:-}"

      if [ ! -d "$PATCHES_DIR" ]; then
        echo "Error: patches dir $PATCHES_DIR not found. Run generate-patches first."
        exit 1
      fi

      # Expand to absolute path and change into target output directory
      PATCHES_DIR="$(cd "$PATCHES_DIR" && pwd)"
      cd "$PATCHES_DIR"

      SECRETS_FLAG=""
      if [ -n "$SECRETS_FILE" ]; then
        SECRETS_FLAG="--with-secrets $SECRETS_FILE"
      fi

      # Collect all *.yaml files in the patches directory (skipping raw cilium.yaml served over HTTP and nvidia patches for non-nvidia nodes)
      PATCH_FLAGS=""
      for f in "$PATCHES_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
          cilium.yaml|nfs.yaml|control.yaml|worker*.yaml) continue ;;
        esac
        ${lib.optionalString (!machine.nvidia) ''
          case "$(basename "$f")" in
            nvidia*) continue ;;
          esac
        ''}
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @$f"
      done

      ${lib.optionalString (machine.nvidia) ''
        # Nvidia kernel modules — per-machine, only for GPU nodes
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @${nvidiaPatch.kernelModulesPatch}"
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @${nvidiaPatch.containerdPatch}"
      ''}

      echo "Generating config for ${machine.name} (${outputType})..."

      ${pkgs.talosctl}/bin/talosctl gen config \
        "${clusterName}" \
        "${clusterEndpoint}" \
        --talos-version "${talosVersion}" \
        --output-types "${if machine.controlPlane then "controlplane,talosconfig" else "worker"}" \
        $PATCH_FLAGS \
        --config-patch @${machinePatch} \
        ${lib.concatMapStringsSep " \\\n    " (p: "--config-patch @${p}") machine.extraPatches} \
        $SECRETS_FLAG \
        --with-docs=false \
        --with-examples=false \
        --force

      if [ -f "controlplane.yaml" ]; then
        mv controlplane.yaml "${machine.name}.yaml"
      fi
      if [ -f "worker.yaml" ]; then
        mv worker.yaml "${machine.name}.yaml"
      fi

      # Strip redundant empty HostnameConfig document appended by talosctl gen config
      sed -i '/---/,$ d' "${machine.name}.yaml"

      chmod 644 "${machine.name}.yaml"
      echo "  → ${machine.name}.yaml"

      ${lib.optionalString (machine.controlPlane) ''
        ${pkgs.talosctl}/bin/talosctl --talosconfig talosconfig config endpoint 10.211.0.30
        chmod 644 talosconfig
        echo "  → talosconfig"
      ''}
    '';

in
{
  inherit mkGeneratePatches mkMachineConfig;
}

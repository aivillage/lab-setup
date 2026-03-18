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
  inputs,
}:

let
  kubelib = inputs.nix-kube-generators.lib { inherit pkgs; };

  # ── Per-machine patch: hostname + network + install ───────────
  mkMachinePatch =
    { machine, schematic }:
    let
      installerImage = "factory.talos.dev/installer/${builtins.readFile schematic}:${machine.version}";
      networkYaml = lib.concatMapStringsSep "\n" (
        dev:
        let
          iface = machine.network-interfaces.${dev};
        in
        "      - interface: ${dev}\n        dhcp: false\n        addresses:\n          - ${iface.ip}/24"
      ) (lib.attrNames machine.network-interfaces);
    in
    pkgs.writeText "${machine.name}-machine-patch.yaml" ''
      machine:
        network:
          hostname: ${machine.name}
          interfaces:
      ${networkYaml}
        install:
          image: ${installerImage}
          disk: null
          wipe: true
          diskSelector:
            size: ${toString machine.diskSelector.size}
    '';

  # ── Generate a patches directory ──────────────────────────────
  #
  # Accepts lab-specific parameters (NFS server, paths, model store)
  # and builds cilium, nvidia, nfs, and model-store patches internally.
  # Extra { name, file } patches can be appended via `extraPatches`.
  #
  mkGeneratePatches =
    {
      nfsServer,
      nfsPath,
      modelStoreName ? "model-store",
      modelStorePath,
      extraPatches ? [ ],
    }:
    let
      ciliumPatch = import ./patches/cilium.nix { inherit pkgs kubelib; };
      nvidiaPatch = import ./patches/nvidia.nix { inherit pkgs kubelib; };
      nfsPatch = import ./patches/nfs.nix {
        inherit pkgs kubelib;
        server = nfsServer;
        path = nfsPath;
      };
      modelStorePatch = import ./patches/model-store.nix {
        inherit pkgs kubelib;
        server = nfsServer;
        path = modelStorePath;
        name = modelStoreName;
      };

      patches = [
        {
          name = "cilium.yaml";
          file = ciliumPatch;
        }
        {
          name = "nvidia-helm.yaml";
          file = nvidiaPatch.helmPatch;
        }
        {
          name = "nfs.yaml";
          file = nfsPatch;
        }
        {
          name = "model-store.yaml";
          file = modelStorePatch;
        }
      ]
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
      nvidiaKernelPatch ? null,
    }:
    let
      machinePatch = mkMachinePatch { inherit machine schematic; };
      outputType = if machine.controlPlane then "controlplane" else "worker";
    in
    pkgs.writeShellScriptBin "generate-config-${machine.name}" ''
      set -euo pipefail

      PATCHES_DIR="''${1:?Usage: generate-config-${machine.name} <patches-dir> [secrets-file]}"
      SECRETS_FILE="''${2:-}"

      if [ ! -d "$PATCHES_DIR" ]; then
        echo "Error: patches dir $PATCHES_DIR not found. Run generate-patches first."
        exit 1
      fi

      SECRETS_FLAG=""
      if [ -n "$SECRETS_FILE" ]; then
        SECRETS_FLAG="--with-secrets $SECRETS_FILE"
      fi

      # Collect all *.yaml files in the patches directory
      PATCH_FLAGS=""
      for f in "$PATCHES_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @$f"
      done

      ${lib.optionalString (machine.nvidia && nvidiaKernelPatch != null) ''
        # Nvidia kernel modules — per-machine, only for GPU nodes
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @${nvidiaKernelPatch}"
      ''}

      echo "Generating config for ${machine.name} (${outputType})..."

      ${pkgs.talosctl}/bin/talosctl gen config \
        "${clusterName}" \
        "${clusterEndpoint}" \
        --talos-version "${talosVersion}" \
        --output-types "${outputType}" \
        --output "${machine.name}.yaml" \
        $PATCH_FLAGS \
        --config-patch @${machinePatch} \
        ${lib.concatMapStringsSep " \\\n    " (p: "--config-patch @${p}") machine.extraPatches} \
        $SECRETS_FLAG \
        --with-docs=false \
        --with-examples=false \
        --force

      chmod 644 "${machine.name}.yaml"
      echo "  → ${machine.name}.yaml"
    '';

in
{
  inherit mkGeneratePatches mkMachineConfig mkMachinePatch;
}

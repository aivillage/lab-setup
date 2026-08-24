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
    { machine, schematic ? null }:
    let
      installerImage = "factory.talos.dev/installer/__SCHEMATIC_ID__:${machine.version}";
      ifaces = machine.network-interfaces or machine.networkInterfaces or { };
      explicitPrimary = lib.filterAttrs (_name: iface: iface.primary or false) ifaces;
      primaryIfaceName =
        if explicitPrimary != { } then
          lib.head (lib.attrNames explicitPrimary)
        else if ifaces != { } then
          lib.head (lib.attrNames ifaces)
        else
          null;
      rawKeys = lib.attrNames ifaces;
      sortedOther = lib.sort (a: b:
        let
          aIsSfp = lib.hasInfix "f" a;
          bIsSfp = lib.hasInfix "f" b;
        in
          if aIsSfp != bIsSfp then !aIsSfp else a < b
      ) (lib.filter (n: n != primaryIfaceName) rawKeys);
      orderedIfaceNames = lib.optional (primaryIfaceName != null) primaryIfaceName ++ sortedOther;
      ifaceList =
        lib.imap0 (idx: name:
          let
            ifaceAttrs = ifaces.${name};
            isPrimary = name == primaryIfaceName;
          in {
            interface = name;
            dhcp = isPrimary;
            dhcpOptions = {
              routeMetric = if isPrimary then 1024 else (2048 + (idx * 1024));
            };
          }
        ) orderedIfaceNames;


      patchObj = {
        machine = {
          type = if machine.controlPlane then "controlplane" else "worker";
          network = {
            hostname = machine.name;
            nameservers = machine.upstreamDns;
          } // (if ifaceList != [ ] then { interfaces = ifaceList; } else { });
          time = {
            disabled = false;
            servers = machine.upstreamNtp;
          };
          kubelet = {
            nodeIP = {
              validSubnets = [ machine.clusterSubnet ];
            };
          };
          install = {
            image = installerImage;
            wipe = true;
          } // (
            if (machine.osDisk or null) != null then { disk = machine.osDisk; }
            else if (machine.diskSelector or null) != null then { diskSelector = machine.diskSelector; }
            else { diskSelector = { size = "< 1TB"; }; }
          );
        };
      };
    in
    pkgs.writeText "${machine.name}-machine-patch.yaml" (builtins.toJSON patchObj);
  nvidiaPatch =
    if kubelib != null then import ./patches/nvidia.nix { inherit pkgs kubelib; } else null;
  # ── Generate a patches directory ───────────────────────────
  mkGeneratePatches =
    {
      nfsServer ? "",
      nfsPath ? "/data",
      extraPatches ? [ ],
      coordinatorIp,
      webserverHost ? "http://${coordinatorIp}:8080/configs",
      bootstrapCNI ? null,
      k8sManifests ? [ ],
      talosPatches ? [ ],
      overrides ? { },
    }:
    let
      resolvePatch = name: defaultFile:
        if overrides ? ${name} then overrides.${name} else defaultFile;

      ciliumPatch =
        if kubelib != null then import ./patches/cilium.nix { inherit pkgs kubelib; } else null;
      cniLoaderPatch = import ./patches/cilium-loader.nix {
        inherit pkgs;
        host = webserverHost;
        ciliumPatchName = if bootstrapCNI != null then "cni.yaml" else "cilium.yaml";
      };

      nvidiaPatches =
        if nvidiaPatch != null then
          [
            {
              name = "addons/nvidia-helm.yaml";
              file = resolvePatch "nvidia-runtime" nvidiaPatch.helmPatch;
            }
            {
              name = "addons/nvidia-runtime.yaml";
              file = resolvePatch "nvidia-runtime" nvidiaPatch.runtimeClassPatch;
            }
          ]
        else
          [ ];

      nfsPatch =
        if nfsServer != "" && kubelib != null then
          [
            {
              name = "addons/nfs.yaml";
              file = resolvePatch "nfs-storage" (import ./patches/nfs.nix {
                inherit pkgs kubelib;
                server = nfsServer;
                path = nfsPath;
              });
            }
          ]
        else
          [ ];

      # Process custom path items or overrides passed in talosPatches & k8sManifests
      customTalosPatches = map (m:
        if lib.isPath m || lib.isDerivation m then {
          name = "base-patches/${builtins.baseNameOf (toString m)}";
          file = m;
        } else if lib.isAttrs m && m ? name && m ? file then {
          name = "base-patches/${m.name}";
          file = m.file;
        } else if lib.isString m && overrides ? ${m} then {
          name = "base-patches/${builtins.baseNameOf (toString overrides.${m})}";
          file = overrides.${m};
        } else null
      ) (lib.filter (x: x != null) talosPatches);

      customK8sPatches = map (m:
        if lib.isPath m || lib.isDerivation m then {
          name = "addons/${builtins.baseNameOf (toString m)}";
          file = m;
        } else if lib.isAttrs m && m ? name && m ? file then {
          name = "addons/${m.name}";
          file = m.file;
        } else if lib.isString m && overrides ? ${m} then {
          name = "addons/${builtins.baseNameOf (toString overrides.${m})}";
          file = overrides.${m};
        } else null
      ) (lib.filter (x: x != null) k8sManifests);

      basePatches = [
        {
          name = "base-patches/schedule.yaml";
          file = ./patches/schedule.yaml;
        }
        {
          name = "base-patches/cni-loader.yaml";
          file = cniLoaderPatch;
        }
      ] ++ (lib.filter (x: x != null) customTalosPatches);

      cniManifest =
        if bootstrapCNI != null then
          {
            name = "cni.yaml";
            file = bootstrapCNI;
          }
        else if ciliumPatch != null then
          {
            name = "cilium.yaml";
            file = resolvePatch "cilium" ciliumPatch;
          }
        else null;

      addonPatches = [
        {
          name = "addons/apiserver-kubelet-rbac.yaml";
          file = resolvePatch "apiserver-rbac" ./patches/apiserver-kubelet-rbac.yaml;
        }
      ]
      ++ lib.optional (cniManifest != null) cniManifest
      ++ nvidiaPatches
      ++ nfsPatch
      ++ extraPatches
      ++ (lib.filter (x: x != null) customK8sPatches);

      patches = basePatches ++ addonPatches;
    in
    pkgs.writeShellScriptBin "generate-patches" ''
      set -euo pipefail

      OUTPUT_DIR="''${1:-.cluster/patches}"
      mkdir -p "$OUTPUT_DIR/base-patches" "$OUTPUT_DIR/addons"

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
      if [ -n "$SECRETS_FILE" ]; then
        SECRETS_DIR="$(cd "$(dirname "$SECRETS_FILE")" 2>/dev/null && pwd || echo "")"
        if [ -n "$SECRETS_DIR" ]; then
          SECRETS_FILE="$SECRETS_DIR/$(basename "$SECRETS_FILE")"
        fi
      fi
      PATCHES_DIR="$(cd "$PATCHES_DIR" && pwd)"
      cd "$PATCHES_DIR"

      SECRETS_FLAG=""
      if [ -n "$SECRETS_FILE" ] && [ -f "$SECRETS_FILE" ]; then
        SECRETS_FLAG="--with-secrets $SECRETS_FILE"
      fi

      # Collect all base patches from base-patches directory without fragile filename filtering
      PATCH_FLAGS=""
      if [ -d "$PATCHES_DIR/base-patches" ]; then
        for f in "$PATCHES_DIR/base-patches"/*.yaml; do
          [ -f "$f" ] || continue
          PATCH_FLAGS="$PATCH_FLAGS --config-patch @$f"
        done
      fi



      ${lib.optionalString (machine.nvidia) ''
        # Nvidia kernel modules — per-machine, only for GPU nodes
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @${nvidiaPatch.kernelModulesPatch}"
        PATCH_FLAGS="$PATCH_FLAGS --config-patch @${nvidiaPatch.containerdPatch}"
      ''}

      echo "Generating config for ${machine.name} (${outputType})..."

      SCHEMATIC_ID=$(cat ${schematic})
      MACHINE_PATCH=$(mktemp --suffix=-${machine.name}-patch.json)
      ${pkgs.gnused}/bin/sed "s|__SCHEMATIC_ID__|$SCHEMATIC_ID|g" ${machinePatch} > "$MACHINE_PATCH"

      ${pkgs.talosctl}/bin/talosctl gen config \
        "${clusterName}" \
        "${clusterEndpoint}" \
        --talos-version "${talosVersion}" \
        --output-types "${if machine.controlPlane then "controlplane,talosconfig" else "worker"}" \
        $PATCH_FLAGS \
        --config-patch @"$MACHINE_PATCH" \
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

      # Strip conflicting HostnameConfig document and base disk line if diskSelector is present
      ${pkgs.python3}/bin/python3 -c '
import sys, re
content = open("${machine.name}.yaml").read()
docs = re.split(r"\n---\n?", content)
filtered = [d for d in docs if "HostnameConfig" not in d]
text = "\n---\n".join(filtered).strip() + "\n"
if "diskSelector:" in text:
    lines = [l for l in text.splitlines() if not re.match(r"^\s*disk:\s*", l)]
    text = "\n".join(lines) + "\n"
open("${machine.name}.yaml", "w").write(text)
'
      # Validate generated MachineConfig against Talos schema
      if ! ${pkgs.talosctl}/bin/talosctl validate --config "${machine.name}.yaml" --mode container >/dev/null 2>&1; then
        VAL_ERR=$(${pkgs.talosctl}/bin/talosctl validate --config "${machine.name}.yaml" --mode container 2>&1 || true)
        CLEAN_ERR=$(echo "$VAL_ERR" | grep -v "issuing CA key" | grep -v "1 error occurred:" || true)
        if [ -n "$CLEAN_ERR" ]; then
          echo "$CLEAN_ERR"
          exit 1
        fi
      fi

      echo "  → ${machine.name}.yaml (validated)"

      ${lib.optionalString (machine.controlPlane) ''
        ENDPOINT_IP="$(echo "${clusterEndpoint}" | sed -E 's|https://(.*):6443|\1|')"
        ${pkgs.talosctl}/bin/talosctl --talosconfig talosconfig config endpoint "$ENDPOINT_IP"
        chmod 644 talosconfig
        echo "  → talosconfig"
      ''}
    '';

in
{
  inherit mkGeneratePatches mkMachineConfig;
}

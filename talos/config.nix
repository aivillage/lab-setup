# lab-setup/talos/config.nix
#
# Two concerns:
#   mkGeneratePatches  — script that writes all helm/secret patches to a dir
#   mkMachineConfig    — script that generates one machine's talos config,
#                        taking the patches dir as input
#
{ pkgs, lib, inputs }:

let
  # ── 1) Generate shared patches (helm + secrets) ───────────────
  #
  # Writes cilium, ghcr, nvidia, nfs, model-store, etc. into a
  # directory. Run once, then point mkMachineConfig at the output.
  #
  mkGeneratePatches = {
    nfsServer ? null,
    mainPath  ? null,
    vllmPath  ? null,
  }:
    let
      kubelib = inputs.nix-kube-generators.lib { inherit pkgs; };

      ciliumFile    = import ./patches/cilium.nix { inherit pkgs kubelib; };
      ghcrAuthFile  = import ./patches/ghcr.nix { inherit pkgs; };
      nvidia        = import ./patches/nvidia.nix { inherit pkgs kubelib; };
      mainPvcFile   = import ./patches/nfs.nix {
        inherit pkgs kubelib;
        server = nfsServer;
        path = mainPath;
      };
      modelPvcFile  = import ./patches/model-store.nix {
        inherit pkgs kubelib;
        server = nfsServer;
        path = vllmPath;
        name = "model-store";
      };
    in
    pkgs.writeShellScriptBin "generate-patches" ''
      set -euo pipefail

      OUTPUT_DIR="''${1:-.talos/patches}"
      mkdir -p "$OUTPUT_DIR"

      echo "Generating shared patches → $OUTPUT_DIR"

      cp -f ${ciliumFile}                  "$OUTPUT_DIR/cilium.yaml"
      cp -f ${ghcrAuthFile}                "$OUTPUT_DIR/ghcr.yaml"
      cp -f ${nvidia.helmPatch}            "$OUTPUT_DIR/nvidia-plugin.yaml"
      cp -f ${nvidia.kernelModulesPatch}   "$OUTPUT_DIR/nvidia-kernel.yaml"
      cp -f ${mainPvcFile}                 "$OUTPUT_DIR/nfs.yaml"
      cp -f ${modelPvcFile}                "$OUTPUT_DIR/model-store.yaml"
      cp -f ${./patches/control.yaml}      "$OUTPUT_DIR/control.yaml"

      echo "✅ Patches written to $OUTPUT_DIR"
    '';

  # ── Per-machine patch: hostname + network + install ───────────
  #
  # Generates machine.install from machine.diskSelector.
  # Currently only diskSelector.size is supported.
  #
  mkMachinePatch = machine:
    let
      networkYaml = lib.concatMapStringsSep "\n" (dev:
        let iface = machine.network-interfaces.${dev}; in ''
          - interface: ${dev}
            dhcp: false
            addresses:
              - ${iface.ip}/24
        ''
      ) (lib.attrNames machine.network-interfaces);
    in
    pkgs.writeText "${machine.name}-machine-patch.yaml" ''
      machine:
        network:
          hostname: ${machine.name}
          interfaces:
      ${networkYaml}
        install:
          disk: null
          wipe: true
          diskSelector:
            size: ${toString machine.diskSelector.size}
    '';

  # ── 2) Generate a single machine's config ─────────────────────
  #
  # Layers: shared patches → control patch (if CP) → nvidia (if applicable)
  #         → machine patch → extraPatches
  #
  mkMachineConfig = {
    machine,
    clusterName,
    clusterEndpoint,
    talosVersion,
    primaryIp,
  }:
    let
      machinePatch = mkMachinePatch machine;
      outputType = if machine.controlPlane then "controlplane" else "worker";

      # Shared patches applied to every node
      sharedPatches = [
        "cilium.yaml"
        "ghcr.yaml"
        "nfs.yaml"
        "model-store.yaml"
        "nvidia-plugin.yaml"
        "control.yaml"
      ];

      sharedFlags = lib.concatMapStringsSep " \\\n    "
        (f: "--config-patch @\"$PATCHES_DIR/${f}\"") sharedPatches;

      controlFlag = lib.optionalString machine.controlPlane
        "--config-patch @\"$PATCHES_DIR/control.yaml\"";

      nvidiaFlag = lib.optionalString machine.nvidia
        "--config-patch @\"$PATCHES_DIR/nvidia-kernel.yaml\"";

      extraFlags = lib.concatMapStringsSep " \\\n    "
        (p: "--config-patch @${p}") machine.extraPatches;
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

      echo "Generating config for ${machine.name} (${outputType})..."

      ${pkgs.talosctl}/bin/talosctl gen config \
        "${clusterName}" \
        "${clusterEndpoint}" \
        --install-disk "" \
        --talos-version "${talosVersion}" \
        --output-types "${outputType}" \
        --output "${machine.name}.yaml" \
        ${sharedFlags} \
        ${nvidiaFlag} \
        --config-patch @${machinePatch} \
        ${extraFlags} \
        $SECRETS_FLAG \
        --force

      chmod 644 "${machine.name}.yaml"
      echo "  → ${machine.name}.yaml"
    '';

in
{
  inherit mkGeneratePatches mkMachineConfig;
}
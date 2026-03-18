# ═══════════════════════════════════════════════════════════════════
# FILE 1: talos/config.nix  (full replacement)
# ═══════════════════════════════════════════════════════════════════
#
# Three concerns, cleanly separated:
#   mkMachinePatch     — per-machine YAML patch (hostname, network, disk)
#   mkMachineConfig    — generates one machine's talos config from a
#                        patches directory (no baked-in patch list)
#   mkGeneratePatches  — lab-specific helper that writes patch files
#                        from a list of { name, file } attrsets
#
{
  pkgs,
  lib,
  inputs,
}:

let
  # ── Per-machine patch: hostname + network + install ───────────
  #
  # Generates machine.install from machine.diskSelector.
  # Currently only diskSelector.size is supported.
  #
  mkMachinePatch =
    machine:
    let
      networkYaml = lib.concatMapStringsSep "\n" (
        dev:
        let
          iface = machine.network-interfaces.${dev};
        in
        ''
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

  # ── Generate a patches directory from a list of files ─────────
  #
  # Takes a list of { name = "cilium.yaml"; file = <derivation>; }
  # and writes them all into a directory. Each lab composes its own
  # patch set; lab-setup doesn't dictate which patches exist.
  #
  mkGeneratePatches =
    {
      patches ? [ ],
    }:
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
  #
  # Applies every *.yaml in the patches directory, plus the machine
  # patch and (conditionally) the nvidia kernel patch.
  #
  # The patches directory is opaque — whatever the lab's
  # generate-patches put in there gets applied. No hardcoded list.
  #
  mkMachineConfig =
    {
      machine,
      clusterName,
      clusterEndpoint,
      talosVersion,
      nvidiaKernelPatch ? null,
    }:
    let
      machinePatch = mkMachinePatch machine;
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
        --force

      chmod 644 "${machine.name}.yaml"
      echo "  → ${machine.name}.yaml"
    '';

in
{
  inherit mkGeneratePatches mkMachineConfig mkMachinePatch;
}

# =============================================================================
# nix/dev_patches.nix
# Development-specific patches for QEMU Talos cluster
# Uses con_shell patch generators with dev-specific overrides
# =============================================================================
{ pkgs, lib, config, name, ... }:
let
  inherit (lib) types mkOption mkIf;

  # Import con_shell patch generators
  cilium_patch = import ../talos/patches/cilium.nix {
    inherit pkgs;
    kubelib = config.kubelib;
  };

  ghcr_patch = import ../talos/patches/ghcr.nix {
    inherit pkgs;
  };

  # Script to generate all dev patches
  generateDevPatchesScript = pkgs.writeShellApplication {
    name = "generate-dev-patches";
    text = ''
      set -euo pipefail
      
      echo "🔧 Generating development patches..."
      mkdir -p "${config.dataDir}"
      cp -f "${cilium_patch}" "${config.dataDir}/cilium.yaml"
      cp -f "${ghcr_patch}" "${config.dataDir}/ghcr.yaml"
    '';
  };

in
{
  options = {
    kubelib = mkOption {
      type = types.attrs;
      description = "Kubelib to generate the chart.";
    };
  };

  config = mkIf config.enable {
    outputs.settings.processes = {
      "${name}" = {
        command = "${generateDevPatchesScript}/bin/generate-dev-patches";
      };
    };
  };
}
# =============================================================================
# nix/dev_patches.nix
# Development-specific patches for QEMU Talos cluster
# Uses con_shell patch generators with dev-specific overrides
# =============================================================================
{
  pkgs,
  lib,
  config,
  name,
  ...
}:
let
  inherit (lib) types mkOption mkIf;

  aivLabSettings = (import ./settings.nix { inherit pkgs; }).aiv-lab;

  bootstrapPatch = import ../talos/patches/bootstrap.nix {
    inherit pkgs;
    manifests = [
      "cilium"
    ];
    host = "http://${aivLabSettings.host}:${builtins.toString aivLabSettings.webserver.port}";
  };

  traefik = import ../talos/patches/traefik.nix {
    inherit pkgs;
    kubelib = config.kubelib;
  };

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
      mkdir -p "${aivLabSettings.patches.storagePath}"
      cp -f "${bootstrapPatch}" "${aivLabSettings.patches.storagePath}/bootstrap.yaml"
      cp -f "${cilium_patch}" "${aivLabSettings.patches.storagePath}/cilium.yaml"
      cp -f "${ghcr_patch}" "${aivLabSettings.patches.storagePath}/ghcr.yaml"
      cp -f "${traefik}" "${aivLabSettings.patches.storagePath}/traefik.yaml"
      echo "Development patches created"
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

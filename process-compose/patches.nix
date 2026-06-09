# =============================================================================
# nix/dev_patches.nix
# Development-specific patches for QEMU Talos cluster
# Uses con_shell patch generators with dev-specific overrides
# =============================================================================
{
  config,
  lib,
  name,
  pkgs,
  ...
}:
let
  inherit (lib) types mkOption mkIf;

  cfg = config;
  aivLabSettings = (import ./settings.nix { inherit pkgs; }).aiv-lab;

  bootstrapPatch = import ../talos/patches/bootstrap.nix {
    inherit pkgs;
    manifests = [
      "cilium"
    ];
    host = "http://${cfg.webserverHost}";
  };

  traefik = lib.aivLab.mkPatchTraefik {
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
      mkdir -p "${cfg.dataDir}"
      cp -f "${bootstrapPatch}" "${cfg.dataDir}/bootstrap.yaml"
      cp -f "${cilium_patch}" "${cfg.dataDir}/cilium.yaml"
      cp -f "${ghcr_patch}" "${cfg.dataDir}/ghcr.yaml"
      cp -f "${traefik}" "${cfg.dataDir}/traefik.yaml"
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
    webserverHost = mkOption {
      type = types.str;
      description = "Host and IP from containers.lab.webserver";
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

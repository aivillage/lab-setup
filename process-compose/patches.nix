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

  # Import patch generators
  cilium_patch = import ../talos/patches/cilium.nix {
    inherit pkgs;
    kubelib = config.kubelib;
  };

  cilium_loader = import ../talos/patches/cilium-loader.nix {
    inherit pkgs;
    ciliumPatchName = "cilium.yaml";
    host = "http://${cfg.webserverHost}";
  };

  ghcr_patch = import ../talos/patches/ghcr.nix {
    inherit pkgs;
  };

  # dynamic patch generation based on value
  isRawString = builtins.isString cfg.dynamicPatch;
  renderedDynamicPatch =
    if isRawString then
      pkgs.writeText "dynamic-patch.yaml" cfg.dynamicPatch
    else
      (pkgs.formats.yaml { }).generate "dynamic-patch.yaml" cfg.dynamicPatch;
  hasDynamicPatch = cfg.dynamicPatch != { } && cfg.dynamicPatch != [ ] && cfg.dynamicPatch != "";

  generatePatchesScript = pkgs.writeShellApplication {
    name = "generate-patches";
    text = ''
      set -euo pipefail

      echo "🔧 Generating development patches..."
      echo "Creating the following directory: $PWD/${config.dataDir}"
      mkdir -p "${cfg.dataDir}"
      ${lib.optionalString hasDynamicPatch ''
          echo "Generating dynamic patch..."
        cp -f "${renderedDynamicPatch}" "${cfg.dataDir}/dynamic.yaml"
      ''}
      cp -f "${cilium_loader}" "${cfg.dataDir}/cilium-loader.yaml"
      cp -f "${cilium_patch}" "${cfg.dataDir}/cilium.yaml"
      cp -f "${ghcr_patch}" "${cfg.dataDir}/ghcr.yaml"
      printf "\n✅ Development patches created\n"
      ls -1 ${cfg.dataDir}
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
    dynamicPatch = mkOption {
      type = types.unspecified; # allows either attr set or raw yaml
      default = { };
      description = ''
        A dynamic patch to apply to the Talos cluster.

        This module accepts either a native Nix attribute set (which will be
        compiled into YAML and guarantees syntactic correctness) OR a raw
        multi-line YAML string.
      '';
      example = lib.literalExpression ''
        # =====================================================================
        # Method 1: Native Nix Attribute Set (Recommended)
        # =====================================================================
        {
          machine = {
            registries = {
              config = {
                "ghcr.io" = {
                  auth = {
                    auth = "base64encodedcredentials";
                  };
                };
              };
            };
            time = {
              bootTimeout = "2m";
            };
          };
        }

        # =====================================================================
        # Method 2: Raw YAML String
        # =====================================================================
        '''
          machine:
            registries:
              config:
                ghcr.io:
                  auth:
                    auth: "base64encodedcredentials"
            time:
              bootTimeout: 2m
        '''
      '';
    };

  };

  config = mkIf config.enable {
    outputs.settings.processes = {
      "patches" = {
        command = "${generatePatchesScript}/bin/generate-patches";
      };
    };
  };
}

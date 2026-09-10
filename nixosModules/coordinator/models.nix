# =====================================================================
# lab-setup: Coordinator Hugging Face Model Cache Module
#
# Configures declarative downloading and caching of model weights on
# the coordinator NVMe filesystem using flock and huggingface-hub CLI.
# =====================================================================

{
  config,
  lib,
  pkgs,
  inputs ? null,
  lab ? null,
  ...
}:

let
  cfg = config.lab.coordinator;
  labSafe = if lab != null then lab else { };
  inputsSafe = if inputs != null then inputs else { };
in
{
  options.lab.coordinator.models = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Declarative Hugging Face model pre-seeder on coordinator";
    };
    storageDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/models";
      description = "Storage directory on coordinator NVMe for cached model weights";
    };
    cacheList = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.unique (
        (labSafe.coordinator.models or [ ])
        ++ (inputsSafe.workshops.workshopInfo.requiredModels or [ ])
      );
      description = "List of Hugging Face models to cache on coordinator NVMe";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.models.enable) {
    systemd.services = lib.listToAttrs (map (model: {
      name = "coordinator-model-cache-${lib.replaceStrings [ "/" "." ] [ "-" "-" ] model}";
      value = {
        description = "AI Village Model Cache: ${model}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        path = [
          pkgs.python313Packages.huggingface-hub
          pkgs.coreutils
          pkgs.bash
          pkgs.util-linux
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "30s";
          TimeoutStartSec = "3600s";
          ExecStart = pkgs.writeShellScript "cache-${lib.replaceStrings [ "/" "." ] [ "-" "-" ] model}" ''
            set -euo pipefail

            if [ -f "${config.sops.secrets."hf-token".path or "/run/secrets/hf-token"}" ]; then
              export HF_TOKEN=$(cat "${config.sops.secrets."hf-token".path or "/run/secrets/hf-token"}")
            fi

            TARGET_DIR="${cfg.models.storageDir}/${model}"
            mkdir -p "$TARGET_DIR"

            echo "=== [Model Cache]: Waiting for lock to verify ${model} ==="
            flock "${cfg.models.storageDir}/.cache.lock" \
              hf download \
                "${model}" \
                --local-dir "$TARGET_DIR"

            echo "=== [Model Cache]: Successfully verified ${model} in $TARGET_DIR ==="
          '';
        };
      };
    }) (lib.unique cfg.models.cacheList));
  };
}

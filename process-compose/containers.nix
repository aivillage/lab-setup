{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    types
    mkEnableOption
    mkOption
    optionalAttrs
    ;

  # 'config' here automatically represents services.containers.<instance-name>
  cfg = config;
  host = if pkgs.stdenv.isDarwin then "host.docker.internal" else "10.5.0.1";

in
{
  options = {
    registries = {
      enable = lib.mkEnableOption "local Docker registry mirrors";

      host = mkOption {
        type = types.str;
        default = host;
        description = "Docker on Macos runs in VM and uses host.docker.internal, else use cidr gateway for cluster.";
      };

      providers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                remoteUrl = lib.mkOption { type = lib.types.str; };

                dataDir = lib.mkOption {
                  type = lib.types.str;
                  default = ".cluster/registries/${name}";
                  description = "Local path for registry storage.";
                };

                localPort = lib.mkOption {
                  type = lib.types.int;
                  default = 8888;
                };

                containerName = lib.mkOption {
                  type = lib.types.str;
                  default = "registry-${name}";
                };
              };
            }
          )
        );
        default = { };
        description = "Attribute set of specific registry mirror providers (e.g., dockerhub, ghcr).";
      };
    };

    webserver = {
      enable = mkEnableOption "nginx webserver";

      patchesDir = lib.mkOption {
        type = types.str;
        default = "";
        description = "Local path for bind mount";
      };

      host = mkOption {
        type = types.str;
        default = host;
        description = "Docker on Macos runs in VM and uses host.docker.internal, else use cidr gateway for cluster.";
      };

      containerName = mkOption {
        type = types.str;
        default = "webserver-talos-patches";
      };

      localPort = mkOption {
        type = types.int;
        default = 5555;
      };

      bindMounts = mkOption {
        type = types.listOf types.str;
        default = [
          "$PWD/${cfg.webserver.patchesDir}:/usr/share/nginx/html:ro"
        ];
        description = "A list of Docker volume bind mounts (e.g., '/host:/container:ro').";
      };
    };
  };

  config = {
    outputs.settings.processes =
      let
        registryProcs = optionalAttrs cfg.registries.enable (
          lib.mapAttrs' (
            regName: regCfg:
            lib.nameValuePair regCfg.containerName {
              command = ''
                ENGINE=$(command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo "/opt/homebrew/bin/podman")
                mkdir -p "$PWD/${regCfg.dataDir}"
                "$ENGINE" rm -f "${regCfg.containerName}" 2>/dev/null || true
                "$ENGINE" run \
                  --rm \
                  --name ${regCfg.containerName} \
                  --dns 8.8.8.8 \
                  -p ${toString regCfg.localPort}:5000 \
                  -e REGISTRY_PROXY_REMOTEURL="${regCfg.remoteUrl}" \
                  -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry \
                  -v "$PWD/${regCfg.dataDir}/:/var/lib/registry:z" \
                  registry:2
              '';

              availability = {
                restart = "on_failure";
                backoff_seconds = 2;
                max_restarts = 10;
              };
            }
          ) cfg.registries.providers
        );

        webserverProc = optionalAttrs cfg.webserver.enable {
          "${cfg.webserver.containerName}" = {
            command = ''
              ENGINE=$(command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo "/opt/homebrew/bin/podman")
              mkdir -p "$PWD/${cfg.webserver.patchesDir}"
              "$ENGINE" rm -f "${cfg.webserver.containerName}" 2>/dev/null || true
              "$ENGINE" run \
                --rm \
                --name ${cfg.webserver.containerName} \
                -p ${toString cfg.webserver.localPort}:80 \
                ${
                  builtins.concatStringsSep " " (builtins.map (mount: "-v \"${mount}\"") cfg.webserver.bindMounts)
                } \
                nginx:latest
            '';
            availability = {
              restart = "on_failure";
              backoff_seconds = 2;
              max_restarts = 10;
            };
          };
        };
      in
      registryProcs // webserverProc;
  };
}

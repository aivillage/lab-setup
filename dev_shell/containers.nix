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
    mkIf
    escapeShellArgs
    optionalAttrs
    ;

  # 'config' here automatically represents services.containers.<instance-name>
  cfg = config;

  # Import global settings directly to bypass module boundaries
  aivLabSettings = (import ./settings.nix { inherit pkgs; }).aiv-lab;

  providerSubModule =
    { name, ... }:
    {
      options = {
        remoteUrl = lib.mkOption { type = lib.types.str; };
        dataDir = lib.mkOption {
          type = lib.types.str;
          default = "${aivLabSettings.registries.storagePath}/${name}";
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
    };

in
{
  options = {
    registries = {
      enable = lib.mkEnableOption "local Docker registry mirrors";

      providers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule providerSubModule);
        default = { };
        description = "Attribute set of specific registry mirror providers (e.g., dockerhub, ghcr).";
      };
    };

    webserver = {
      enable = mkEnableOption "nginx webserver";

      containerName = mkOption {
        type = types.str;
        default = "webserver-talos-patches";
      };
      localPort = mkOption {
        type = types.int;
        default = aivLabSettings.webserver.port;
      };
      bindMounts = mkOption {
        type = types.listOf types.str;
        default = [
          "${aivLabSettings.webserver.storagePath}:/usr/share/nginx/html:ro"
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
              command = escapeShellArgs [
                "docker"
                "run"
                "--dns"
                "8.8.8.8"
                "--name"
                "${regName}"
                "--rm"
                "-p"
                "${toString regCfg.localPort}:5000"
                "-e"
                "REGISTRY_PROXY_REMOTEURL=${regCfg.remoteUrl}"
                "-e"
                "REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry"
                "-v"
                "${regCfg.dataDir}/storage:/var/lib/registry"
                "--name"
                regCfg.containerName
                "registry:2"
              ];

              # Dependency removed. Relying strictly on retries to wait for the network.
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
            command = escapeShellArgs (
              [
                "docker"
                "run"
                "--rm"
                "--name"
                "${cfg.webserver.containerName}"
                "-p"
                "${toString cfg.webserver.localPort}:80"
                "--name"
                cfg.webserver.containerName
              ]
              ++ (builtins.concatMap (mount: [
                "-v"
                mount
              ]) cfg.webserver.bindMounts)
              ++ [ "nginx:latest" ]
            );

            # Dependency removed. Relying strictly on retries to wait for the network.
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

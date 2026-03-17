# nix/registry-mirror.nix
{ pkgs, lib, config, name, ... }:
let
  inherit (lib) types mkOption mkIf;

  # uid = builtins.getEnv "UID";
  # xdgRuntimeDir = "/run/user/1000";
  # dockerHost = "unix://${xdgRuntimeDir}/docker.sock";

  startCommand = [
        "docker"
        "run"
        "--dns" "8.8.8.8"
        "--rm" # Use --rm to auto-clean on stop
        "-p" "${toString config.localPort}:5000"
        "-e" "REGISTRY_PROXY_REMOTEURL=${config.remoteUrl}"
        "-e" "REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/var/lib/registry"
        "-v" "${config.dataDir}/storage:/var/lib/registry"
        "--name" config.containerName
        "registry:2"
      ];
in
{
  options = {
    remoteUrl = mkOption {
      type = types.str;
      description = "The remote URL for the registry proxy.";
      example = "https://registry-1.docker.io";
    };
    localPort = mkOption {
      type = types.int;
      description = "The local port to expose the mirror on.";
      example = 5000;
    };
    containerName = mkOption {
      type = types.str;
      default = "registry-${name}";
      description = "The name for the Docker container.";
    };
  };

  config = mkIf config.enable {
    outputs.settings.processes."${name}" = {
      command = (lib.escapeShellArgs startCommand);
      # environment = [
      #   "DOCKER_HOST=${dockerHost}"
      # ];
    };
  };
}
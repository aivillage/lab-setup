{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    mkEnableOption
    mkIf
    ;

  cfg = config.services.inspector-api;
  inspectorApiPkg = pkgs.writers.writePython3Bin "inspector-api" {
    doCheck = false;
  } (builtins.readFile ../packages/inspector-api/server.py);
in
{
  options.services.inspector-api = {
    enable = mkEnableOption "Inspector API Receiver Service";

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Port to listen on for Inspector YAML report HTTP POSTs";
    };

    reportsDir = mkOption {
      type = types.path;
      default = "/var/lib/inspector/reports";
      description = "Directory to store incoming hardware inspection reports";
    };

    talosSecretsFile = mkOption {
      type = types.path;
      description = ''
        Path to a decrypted Talos secrets bundle (as produced by
        `talosctl gen secrets`, e.g. sops-nix's
        `config.sops.secrets."talos-secrets".path`) used to generate
        machine configs with a consistent cluster CA/bootstrap token
        instead of minting fresh secrets on every request.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.inspector-api = {
      description = "Inspector Hardware Report API Receiver";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PORT = toString cfg.port;
        REPORTS_DIR = cfg.reportsDir;
        TALOS_SECRETS_CREDENTIAL = "talos-secrets";
      };

      serviceConfig = {
        ExecStart = "${lib.getExe inspectorApiPkg}";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = [
          "inspector/reports"
          "inspector-api"
        ];
        StateDirectoryMode = "0755";
        DynamicUser = true;
        LoadCredential = "talos-secrets:${cfg.talosSecretsFile}";
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}

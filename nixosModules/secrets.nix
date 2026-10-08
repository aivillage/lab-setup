{
  config,
  pkgs,
  lib,
  inputs ? { },
  ...
}:

let
  cfg = config.lab.secrets;
in
{
  options.lab.secrets = {
    enable = lib.mkEnableOption "SOPS secrets management via lab";

    backend = lib.mkOption {
      type = lib.types.enum [ "tpm" "ssh" "age" ];
      default = "tpm";
      description = "The decryption backend to use";
    };

    keyPath = lib.mkOption {
      type = lib.types.path;
      description = "Path to the key (TPM stub, SSH host key, or plain age key)";
    };


    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Default path to an encrypted secrets file (optional)";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Attrset of additional secrets mapped to their sops-nix options";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.mkIf (cfg.backend == "tpm") [
      pkgs.age-plugin-tpm
    ];

    sops.defaultSopsFile = lib.mkIf (cfg.secretsFile != null) cfg.secretsFile;
    sops.defaultSopsFormat = "yaml";

    # Bypass sops-nix store check by mapping it into /etc
    environment.etc."sops/key.txt" = lib.mkIf (cfg.backend == "age" || cfg.backend == "tpm") {
      source = cfg.keyPath;
      mode = "0400";
    };

    sops.age.keyFile = lib.mkIf (cfg.backend == "age" || cfg.backend == "tpm") "/etc/sops/key.txt";
    sops.age.sshKeyPaths = lib.mkIf (cfg.backend == "ssh") [ cfg.keyPath ];
    sops.age.generateKey = false;
    sops.age.plugins = lib.mkIf (cfg.backend == "tpm") [ pkgs.age-plugin-tpm ];

    sops.secrets = cfg.secrets;
  };
}

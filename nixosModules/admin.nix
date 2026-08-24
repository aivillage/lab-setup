{ config, lib, pkgs, cluster ? null, ... }:

let
  cfg = config.lab.admin;
in
{
  options.lab.admin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dedicated admin user with PAM SSH agent auth. If false, falls back to root SSH key access.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Username for the admin account.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = if cluster != null && cluster ? authorizedKeys then cluster.authorizedKeys else [ ];
      description = "List of SSH authorized public keys.";
    };
  };

  config = lib.mkMerge [
    # 1. Admin User Enabled Mode
    (lib.mkIf cfg.enable {
      users.users.${cfg.name} = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        shell = pkgs.zsh;
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      };

      security.pam = {
        sshAgentAuth = {
          enable = true;
          authorizedKeysFiles = [ "/etc/ssh/authorized_keys.d/%u" ];
        };
        services.remote = {
          unixAuth = true;
          setLoginUid = true;
          updateWtmp = true;
        };
      };

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };
    })

    # 2. Fallback Mode (Root SSH Access)
    (lib.mkIf (!cfg.enable) {
      users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "prohibit-password";
        };
      };
    })
  ];
}

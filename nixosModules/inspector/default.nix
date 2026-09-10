{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../admin.nix
    ../shell.nix
  ];

  options.inspector = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized for debug console in Inspector RAMDisk";
    };
  };

  config = let
    inspectorReport = pkgs.writeShellApplication {
      name = "inspector-report";
      runtimeInputs = with pkgs; [
        age
        age-plugin-tpm
        coreutils
        curl
        dmidecode
        ethtool
        gawk
        gptfdisk
        hostname
        inspector
        iproute2
        jq
        parted
        pciutils
        systemd
        tpm2-tools
        util-linux
      ];
      text = builtins.readFile ./inspector-report.sh;
    };

    inspectorEmergency = pkgs.writeShellApplication {
      name = "inspector-emergency";
      runtimeInputs = with pkgs; [
        coreutils
        gawk
        gnugrep
        gnused
        hostname
        iproute2
        util-linux
      ];
      text = builtins.readFile ./inspector-emergency.sh;
    };
  in {
    networking.hostName = lib.mkDefault "inspector";
    boot = {
      kernelParams = [ "console=tty0" ];
      zfs.forceImportRoot = false;
    };

    lab.admin = {
      enable = true;
      authorizedKeys = config.inspector.authorizedKeys;
    };
    security.sudo.wheelNeedsPassword = false;

    programs.nix-ld.enable = true;
    environment.systemPackages = with pkgs; [
      age
      age-plugin-tpm
      conntrack-tools
      curl
      dmidecode
      ethtool
      gptfdisk
      htop
      inspector
      jq
      lshw
      parted
      pciutils
      smartmontools
      tcpdump
      tpm2-tools
      usbutils
      util-linux
    ];

    services.getty.autologinUser = lib.mkForce null;

    systemd.services = {
      inspector-report = {
        description = "Run Hardware Inspector and POST report to Coordinator server";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          OnFailure = [ "inspector-emergency.service" ];
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe inspectorReport;
        };
      };

      inspector-emergency = {
        description = "Emergency Diagnostics and SSH Keep-Alive for Inspector";
        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "journal+console";
          StandardError = "journal+console";
          ExecStart = lib.getExe inspectorEmergency;
        };
      };
    };

    system.stateVersion = "25.11";
  };
}

{
  pkgs,
  inputs,
  lib,
  inspectorBin,
  ...
}:
{
  networking.hostName = "inspector";

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/PhAuMI529/ah9/nY27UHo0G/UMCTsZcGhmYk+O3Lv admin@aivillage.org"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai"
  ];

  environment.systemPackages = with pkgs; [
    inspectorBin

    parted
    gptfdisk
    util-linux
    smartmontools
    ethtool
    tcpdump
    conntrack-tools
    pciutils
    usbutils
    lshw
    dmidecode
    htop
    neofetch
  ];

  programs.nix-ld.enable = true;

  fileSystems."/mnt/nas" = {
    device = "10.211.0.10:/mnt/data";
    fsType = "nfs";
    options = [
      "rw"
      "soft"
      "retry=5"
      "nolock"
    ];
  };

  systemd.services.inspector-report = {
    description = "Run Hardware Inspector and save to NAS";

    after = [
      "network.target"
      "mnt-nas.mount"
    ];
    requires = [ "mnt-nas.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      hostname
      util-linux
      coreutils
      gptfdisk
      systemd
      parted
    ];

    script = ''
      ${inspectorBin}/bin/inspector inspect > /mnt/nas/inspector-report-$(hostname).yaml

      if [ -f /mnt/nas/WIPE_ALL ]; then
        TIMESTAMP=$(date +%s)
        LOGFILE="/mnt/nas/wipe-$(hostname)-$TIMESTAMP.log"
        ${inspectorBin}/bin/inspector wipe --confirm > $LOGFILE
      fi

      sync
      poweroff
    '';

    serviceConfig = {
      Type = "oneshot";
    };
  };

  system.stateVersion = "25.11";
}

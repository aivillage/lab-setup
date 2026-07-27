{ modulesPath, pkgs, ... }:
{
  # 1. Enable SSH so you can connect to the installer
  services.openssh.enable = true;

  # Add the admin key to root so you can SSH in to perform the install
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/PhAuMI529/ah9/nY27UHo0G/UMCTsZcGhmYk+O3Lv admin@aivillage.org"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMsmsLubwu6s0wkeKTsM2EIuJRKFsg2nZdRCVtQHk9LT thurs"
  ];

  networking = {
    hostName = "control";
    hostId = "8425e349";
    defaultGateway = "10.211.0.1";
    nameservers = [
      "1.1.1.1"
      "8.8.8.8"
    ];
    interfaces.enp1s0.ipv4.addresses = [
      {
        address = "10.211.0.10";
        prefixLength = 24;
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    disko
    git # To clone this repo if needed
    gptfdisk # For the NVMe drives
    nano
    neovim
    parted # For the OS drive
    zfs # ZFS tools
  ];
}

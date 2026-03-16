{ pkgs, ... }:
{
  # 1. Enable SSH so you can connect to the installer
  services.openssh.enable = true;
  
  # Add the admin key to root so you can SSH in to perform the install
  users.users.root.openssh.authorizedKeys.keys = [ 
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/PhAuMI529/ah9/nY27UHo0G/UMCTsZcGhmYk+O3Lv admin@aivillage.org" 
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai" 
  ];

  networking.interfaces.enp1s0.ipv4.addresses = [{
    address = "10.211.0.10";
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.211.0.1";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
  networking.hostName = "control";
  networking.hostId = "8425e349";

  boot.supportedFilesystems = [ "zfs" ];
  environment.systemPackages = with pkgs; [ 
    parted      # For the OS drive
    gptfdisk    # For the NVMe drives
    zfs         # ZFS tools
    git         # To clone this repo if needed
    neovim
  ];

  environment.etc."nixos/configuration.nix".source = ./configuration.nix;
}
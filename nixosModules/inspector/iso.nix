{ modulesPath, lib, pkgs, inputs, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    inputs.self.nixosModules.inspector
  ];

  # Exclude git from installer systemPackages to prevent Git 2.54 Rust gitcore cross-compilation error
  environment.systemPackages = lib.mkForce (with pkgs; [
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
    usbutils
    util-linux
  ]);
}

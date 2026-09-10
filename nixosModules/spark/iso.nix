{ modulesPath, lib, pkgs, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  users.users.root.openssh.authorizedKeys.keys = lib.mkDefault [ ];

  environment.systemPackages = with pkgs; [
    git
    htop
    gptfdisk
  ];
}

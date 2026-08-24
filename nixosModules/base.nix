{ pkgs, ... }:

{
  imports = [
    ./shell.nix
    ./admin.nix
    ./secrets.nix
  ];

  environment.systemPackages = with pkgs; [
    neovim
    bottom      # Process/resource monitor (`btm`)
    tmux
    htop
    curl
    jq
    git
    pciutils
    exfatprogs
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.config.allowUnfree = true;
}

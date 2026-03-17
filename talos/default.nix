# lab-setup/talos/default.nix
#
# Machine types, images, DHCP.
# Config generation (patches + per-machine) is in config.nix.
#
{
  pkgs,
  lib,
  inputs,
}:
let
  mkMachineType = import ./machine.nix { inherit lib; };
  configLib = import ./config.nix { inherit pkgs lib inputs; };

  baseExtensions = [
    "siderolabs/amd-ucode"
    "siderolabs/intel-ucode"
  ];

  nvidiaExtensions = [
    "siderolabs/nvidia-container-toolkit-lts"
    "siderolabs/nvidia-open-gpu-kernel-modules-lts"
  ];

  mkImage =
    {
      machine,
      version,
      arch ? "amd64",
      sha256,
    }:
    let
      extensions =
        baseExtensions ++ (lib.optionals machine.nvidia nvidiaExtensions) ++ machine.extraExtensions;
    in
    import ./image.nix { inherit pkgs; } {
      inherit version arch sha256;
      platform = "metal";
      systemExtensions = extensions;
      diskImage = "pxe-assets";
    };

  mkMachine =
    {
      machine,
      version,
      arch ? "amd64",
      sha256,
    }:
    {
      inherit machine;
      image = mkImage {
        inherit
          machine
          version
          arch
          sha256
          ;
      };

      dhcpHosts = lib.concatLists (
        lib.mapAttrsToList (_dev: iface: [
          "${iface.mac},${iface.ip},${machine.name}"
        ]) machine.network-interfaces
      );

      primaryIp = builtins.head (lib.mapAttrsToList (_: iface: iface.ip) machine.network-interfaces);
    };

in
{
  inherit mkMachine mkImage mkMachineType;
  inherit (configLib) mkGeneratePatches mkMachineConfig;
}

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
  machineModule = import ../machine.nix { inherit lib; };
  mkMachineType =
    args:
    (lib.evalModules {
      modules = [
        machineModule
        { config = args; }
      ];
    }).config;

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
      machine ? null,
      version ? "v1.12.1",
      arch ? "amd64",
      sha256 ? lib.fakeSha256,
      ...
    }@args:
    let
      # Use machine if provided, or extract it if machine is a machine object,
      # otherwise create it from the remaining arguments.
      m =
        if machine == null then
          mkMachineType (builtins.removeAttrs args [
            "machine"
            "version"
            "arch"
            "sha256"
          ])
        else if machine ? machine then
          machine.machine
        else
          machine;
    in
    {
      name = m.name;
      machine = m;
      image = mkImage {
        machine = m;
        inherit
          version
          arch
          sha256
          ;
      };

      dhcpHosts = lib.concatLists (
        lib.mapAttrsToList (
          _dev: iface: [
            "${iface.mac},${iface.ip},${m.name}"
          ]
        ) m.network-interfaces
      );

      primaryIp = builtins.head (lib.mapAttrsToList (_: iface: iface.ip) m.network-interfaces);
    };


in
{
  inherit mkMachine mkImage mkMachineType;
  inherit (configLib) mkGeneratePatches mkMachineConfig;
}

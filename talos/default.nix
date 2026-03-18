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

  configLib = import ./config.nix { inherit pkgs lib inputs; };

  mkSchematic = (import ./schematic.nix { inherit pkgs lib; }).mkSchematic;

  mkImage =
    {
      machine,
      schematic,
    }:
    import ./image.nix { inherit pkgs; } {
      version = machine.version;
      sha256 = machine.sha256;
      schematic = schematic;

      platform = "metal";
      diskImage = "pxe-assets";
    };

  machine =
    machineAttrs:
    let
      machine = machineAttrs;
      schematic = mkSchematic {
        machine = machine;
        sha256 = machine.schematicSha256;
      };
      installerImage = "factory.talos.dev/installer/${builtins.readFile schematic}:${machine.version}";
    in
    {
      name = machine.name;
      machine = machine;
      image = mkImage {
        machine = machine;
        schematic = schematic;
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
  inherit machine mkImage;
  inherit (configLib) mkGeneratePatches mkMachineConfig mkMachinePatch;
}
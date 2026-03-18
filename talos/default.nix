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
  inherit (lib) types mkOption;

  interfaceType = types.submodule {
    options = {
      ip = mkOption { type = types.str; };
      mac = mkOption { type = types.str; };
    };
  };

  diskSelectorType = types.submodule {
    options = {
      size = mkOption {
        type = types.int;
        description = "Exact disk size in bytes used by Talos diskSelector";
      };
    };
  };

  machineModule = {
    options = {
      version = mkOption {
        type = types.str;
        default = "v1.12.1";
      };
      sha256 = mkOption { type = types.str; };
      schematicSha256 = mkOption { type = types.str; };
      name = mkOption {
        type = types.str;
        description = "Hostname of this machine";
      };
      controlPlane = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this is a control plane node";
      };
      network-interfaces = mkOption {
        type = types.attrsOf interfaceType;
        description = "Network interfaces keyed by device name (e.g. enp1s0)";
      };
      nvidia = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this machine has NVIDIA GPUs";
      };
      diskSelector = mkOption {
        type = diskSelectorType;
        description = "Talos diskSelector for the install target";
        example = {
          size = 512110190592;
        };
      };
      extraExtensions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional Talos system extensions beyond defaults";
      };
      extraPatches = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Additional Talos config patch files for this machine";
      };
      clusterName = mkOption {
        type = types.str;
        description = "Talos cluster name";
        default = "cluster";
      };
      clusterEndpoint = mkOption {
        type = types.str;
        description = "Talos cluster endpoint URL";
        default = "https://127.0.0.1:6443";
      };
    };
  };

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
      eval = lib.evalModules {
        modules = [
          machineModule
          { config = machineAttrs; }
        ];
      };
      cfg = eval.config;

      schematic = mkSchematic {
        machine = cfg;
        sha256 = cfg.schematicSha256;
      };

      configScript = configLib.mkMachineConfig {
        machine = cfg;
        clusterName = cfg.clusterName;
        clusterEndpoint = cfg.clusterEndpoint;
        talosVersion = cfg.version;
        inherit schematic;
      };
    in
    {
      name = cfg.name;
      machine = cfg;
      image = mkImage {
        machine = cfg;
        schematic = schematic;
      };

      dhcpHosts = lib.concatLists (
        lib.mapAttrsToList (_dev: iface: [
          "${iface.mac},${iface.ip},${cfg.name}"
        ]) cfg.network-interfaces
      );

      primaryIp = builtins.head (lib.mapAttrsToList (_: iface: iface.ip) cfg.network-interfaces);
      configScript = configScript;
    };
in
{
  inherit machine;
  inherit (configLib) mkGeneratePatches;
}

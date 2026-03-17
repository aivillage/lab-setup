# lab-setup/talos/machine.nix
{ lib }:
let
  inherit (lib) types mkOption;

  interfaceType = types.submodule {
    options = {
      ip = mkOption { type = types.str; };
      mac = mkOption { type = types.str; };
    };
  };
in
types.submodule {
  options = {
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
      type = types.attrsOf types.anything;
      default = { size = ">=500GB"; };
      description = "Talos diskSelector for install target";
    };

    extraExtensions = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional Talos system extensions beyond defaults";
    };

    extraPatches = mkOption {
      type = types.listOf types.path;
      default = [];
      description = "Additional Talos config patch files for this machine";
    };
  };
}
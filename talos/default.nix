# lab-setup/talos/default.nix
{ pkgs, lib, inputs }:
let
  mkMachineType = import ./machine.nix { inherit lib; };

  # Base extensions every machine gets
  baseExtensions = [
    "siderolabs/amd-ucode"
    "siderolabs/intel-ucode"
  ];

  nvidiaExtensions = [
    "siderolabs/nvidia-container-toolkit-lts"
    "siderolabs/nvidia-open-gpu-kernel-modules-lts"
  ];

  # Build the Talos factory image for a specific machine
  mkImage = { machine, version, arch ? "amd64", sha256 }:
    let
      extensions = baseExtensions
        ++ (lib.optionals machine.nvidia nvidiaExtensions)
        ++ machine.extraExtensions;
    in
    import ./image.nix { inherit pkgs; } {
      inherit version arch sha256;
      platform = "metal";
      systemExtensions = extensions;
      diskImage = "pxe-assets";
    };

  # Generate a machine-specific Talos config patch YAML
  mkMachinePatch = machine:
    let
      # Build network config from interfaces
      networkDevices = lib.mapAttrsToList (dev: iface: {
        interface = dev;
        addresses = [ "${iface.ip}/24" ];
        dhcp = false;
      }) machine.network-interfaces;

      networkYaml = lib.concatMapStringsSep "\n" (d: ''
        - interface: ${d.interface}
          dhcp: false
          addresses:
            - ${builtins.head d.addresses}
      '') networkDevices;

      nvidiaKernelModules = lib.optionalString machine.nvidia ''
        kernel:
          modules:
            - name: nvidia
            - name: nvidia_uvm
            - name: nvidia_drm
            - name: nvidia_modeset
      '';

      diskSelectorYaml = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "      ${k}: ${toString v}") machine.diskSelector
      );
    in
    pkgs.writeText "${machine.name}-patch.yaml" ''
      machine:
        network:
          hostname: ${machine.name}
          interfaces:
      ${networkYaml}
        install:
          disk: null
          wipe: true
          diskSelector:
      ${diskSelectorYaml}
      ${nvidiaKernelModules}
    '';

  # Full per-machine bundle: image + patches + DHCP info
  mkMachine = { machine, version, arch ? "amd64", sha256 }:
    {
      inherit machine;
      image = mkImage { inherit machine version arch sha256; };
      patch = mkMachinePatch machine;

      # Derived DHCP entries for the NAS module
      dhcpHosts = lib.concatLists (lib.mapAttrsToList (_dev: iface: [
        "${iface.mac},${iface.ip},${machine.name}"
      ]) machine.network-interfaces);

      # First IP of first interface — used as the node endpoint
      primaryIp = (builtins.head (
        lib.mapAttrsToList (_: iface: iface.ip) machine.network-interfaces
      ));
    };

in
{
  inherit mkMachine mkImage mkMachinePatch mkMachineType;
}
{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages.inspector-netboot =
        let
          inspectorSystem = inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = { inherit inputs; };
            modules = [
              (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
              ../head/inspector.nix
            ];
          };
        in
        inspectorSystem.config.system.build.netbootRamdisk;
    };
}

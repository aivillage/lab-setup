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
            specialArgs = { inherit inputs; };
            modules = [
              {
                nixpkgs.buildPlatform = system;
                nixpkgs.hostPlatform = "x86_64-linux";
              }
              (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
              inputs.self.nixosModules.inspector
            ];
          };
        in
        pkgs.symlinkJoin {
          name = "inspector-netboot";
          paths = [
            inspectorSystem.config.system.build.kernel
            inspectorSystem.config.system.build.netbootRamdisk
            inspectorSystem.config.system.build.netbootIpxeScript
          ];
        };
    };
}

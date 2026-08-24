{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages = inputs.nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
        inspector-iso =
          let
            inspectorSystem = inputs.nixpkgs.lib.nixosSystem {
              specialArgs = { inherit inputs; };
              modules = [
                {
                  nixpkgs.buildPlatform = system;
                  nixpkgs.hostPlatform = "x86_64-linux";
                }
                inputs.self.nixosModules.inspector-iso
              ];
            };
          in
          inspectorSystem.config.system.build.isoImage;
      };
    };
}

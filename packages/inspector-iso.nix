{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages.inspector-iso =
        let
          inspectorSystem = inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = { inherit inputs; };
            modules = [
              inputs.self.nixosModules.inspector-iso
            ];
          };
        in
        inspectorSystem.config.system.build.isoImage;
    };
}

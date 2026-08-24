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
        aarch64-installer-iso =
          let
            installerSystem = inputs.nixpkgs.lib.nixosSystem {
              specialArgs = { inherit inputs; };
              modules = [
                {
                  nixpkgs.buildPlatform = system;
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                inputs.self.nixosModules.aarch64-installer-iso
              ];
            };
          in
          installerSystem.config.system.build.isoImage;

        aarch64-installer-iso-aiv =
          let
            installerSystem = inputs.nixpkgs.lib.nixosSystem {
              specialArgs = { inherit inputs; };
              modules = [
                {
                  nixpkgs.buildPlatform = system;
                  nixpkgs.hostPlatform = "aarch64-linux";
                }
                inputs.self.nixosModules.aarch64-installer-iso
                {
                  users.users.root.openssh.authorizedKeys.keys = (import ../keys.nix).all;
                }
              ];
            };
          in
          installerSystem.config.system.build.isoImage;
      };
    };
}

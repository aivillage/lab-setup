{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    let
      mkInstaller = extraModules:
        let
          installerSystem = inputs.nixpkgs.lib.nixosSystem {
            specialArgs = { inherit inputs; };
            modules = [
              {
                nixpkgs.buildPlatform = system;
                nixpkgs.hostPlatform = "aarch64-linux";
              }
              inputs.self.nixosModules.spark-iso
            ] ++ extraModules;
          };
        in
        installerSystem.config.system.build.isoImage;
    in
    {
      packages = inputs.nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
        spark-installer-iso = mkInstaller [ ];

        spark-installer-iso-aiv = mkInstaller [
          {
            users.users.root.openssh.authorizedKeys.keys = (import ../../keys.nix).all;
          }
        ];
      };
    };
}

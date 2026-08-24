{ self, inputs, ... }:
{
  flake.flakeModules.cluster =
    { config, lib, ... }:
    let
      cfg = config.cluster;
    in
    {
      options.cluster = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Declarative AI Village cluster configuration";
      };

      config = lib.mkIf (cfg != { }) {
        perSystem =
          { pkgs, system, ... }:
          let
            clusterLib = import "${self}/talos" {
              inherit pkgs inputs;
              lib = pkgs.lib;
            };
            cluster = clusterLib.mkCluster (cfg // { inherit pkgs; });
          in
          {
            devShells.default = cluster.devShell;

            packages = lib.optionalAttrs pkgs.stdenv.isLinux {
              inspector-iso =
                let
                  inspectorSystem = inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = { inherit inputs; };
                    modules = [
                      {
                        nixpkgs.buildPlatform = system;
                        nixpkgs.hostPlatform = "x86_64-linux";
                      }
                      self.nixosModules.inspector-iso
                      {
                        inspector.authorizedKeys = cfg.authorizedKeys or [ ];
                      }
                    ];
                  };
                in
                inspectorSystem.config.system.build.isoImage;

              installer-iso =
                let
                  installerSystem = inputs.nixpkgs.lib.nixosSystem {
                    specialArgs = { inherit inputs; };
                    modules = [
                      {
                        nixpkgs.buildPlatform = system;
                        nixpkgs.hostPlatform = "aarch64-linux";
                      }
                      self.nixosModules.aarch64-installer-iso
                      {
                        users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys or [ ];
                      }
                    ];
                  };
                in
                installerSystem.config.system.build.isoImage;
            };
          };
      };
    };

  flake.flakeModules.default = self.flakeModules.cluster;
}

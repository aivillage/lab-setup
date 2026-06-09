{
  description = "lab-setup: Talos homelab utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # For the development environment
    process-compose-flake = {
      url = "github:Platonic-Systems/process-compose-flake";
    };
    services-flake = {
      url = "github:juspay/services-flake";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    let
      # extend lib, access via lib.aivLab.*
      lib = inputs.nixpkgs.lib.extend (
        final: prev: {
          aivLab = import ./lib { lib = final; };
        }
      );
    in
    inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
        specialArgs = {
          inherit lib;
        };
      }
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];
        imports = [
          inputs.process-compose-flake.flakeModule
          inputs.flake-parts.flakeModules.modules
          ./packages/inspector.nix
          ./devShells
          ./process-compose
        ];
        perSystem =
          {
            config,
            lib,
            pkgs,
            system,
            ...
          }:
          {
            checks = import ./checks.nix { inherit inputs lib pkgs; };
          };

        flake = {
          lib =
            { pkgs }:
            let
              lib = pkgs.lib;
            in
            {
              talos = import ./talos/default.nix { inherit pkgs lib inputs; };
            };

          nixosConfigurations = {
            inspector = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              specialArgs = { inherit inputs; };
              modules = [
                (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
                ./head/inspector.nix
              ];
            };

            # nixos-rebuild build-image --flake .#nas-installer-iso --image-variant iso
            nas-installer-iso = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                ./head/nas-iso.nix
              ];
            };
          };

          nixosModules = {
            pxe =
              { ... }:
              {
                imports = [ ./head/default.nix ];
                _module.args.inspector = inputs.self.nixosConfigurations.inspector;
              };
            iso = import ./head/iso.nix;
          };
        };
      };
}

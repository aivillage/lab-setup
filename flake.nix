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
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";

    services-flake = {
      url = "github:juspay/services-flake";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./devShells
        ./checks.nix
        ./packages/inspector.nix
        ./packages/inspector-api.nix
        ./packages/inspector-iso.nix
        ./packages/inspector-netboot.nix
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        {
          # Apply standard overlays across all perSystem package evaluation
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };

      flake = {
        lib = args@{ pkgs ? null, ... }: {
          talos = import ./talos/default.nix ({ inherit inputs; lib = inputs.nixpkgs.lib; } // args);
        };



        nixosModules = {
          inspector-api = ./nixosModules/inspector-api.nix;

          inspector = { ... }: {
            imports = [ ./nixosModules/inspector.nix ];
            nixpkgs.overlays = [
              (final: prev: {
                inspector = inputs.self.packages.${final.stdenv.hostPlatform.system}.inspector;
              })
            ];
          };

          inspector-iso = { modulesPath, lib, pkgs, ... }: {
            imports = [
              "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
              inputs.self.nixosModules.inspector
            ];
            # Exclude git from installer systemPackages to prevent Git 2.54 Rust gitcore cross-compilation error
            environment.systemPackages = lib.mkForce (with pkgs; [
              conntrack-tools
              curl
              dmidecode
              ethtool
              gptfdisk
              htop
              inspector
              jq
              lshw
              parted
              pciutils
              smartmontools
              tcpdump
              usbutils
              util-linux
            ]);
          };

          pxe = {
            imports = [ ./nixosModules/cnc.nix ];
            _module.args.inputs = inputs;
            _module.args.inspector = (inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                "${inputs.nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
                inputs.self.nixosModules.inspector
              ];
            });
          };
        };
      };
    };
}

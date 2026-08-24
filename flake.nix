{
  description = "lab-setup: Talos homelab utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # for dual DGX Spark machines
    dgx-spark = {
      url = "github:graham33/nixos-dgx-spark";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # For the development environment
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";

    services-flake = {
      url = "github:juspay/services-flake";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.process-compose-flake.flakeModule
        ./process-compose
        ./flakeModules/cluster.nix
        ./devShells
        ./checks.nix
        ./packages/inspector
        ./packages/inspector/iso.nix
        ./packages/inspector/netboot.nix
        ./packages/cluster-cli/package.nix
        ./packages/aarch64-installer-iso.nix
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
        lib = {
          keys = import ./keys.nix;

          mkCluster = args@{ pkgs, ... }:
            (import ./talos/default.nix { inherit inputs pkgs; lib = inputs.nixpkgs.lib; }).mkCluster args;

          mkClusterDevShell = args@{ pkgs, ... }:
            (import ./talos/default.nix { inherit inputs pkgs; lib = inputs.nixpkgs.lib; }).mkClusterDevShell args;
        };

        nixosModules = {
          base = { ... }: {
            imports = [
              ./nixosModules/base.nix
              inputs.sops-nix.nixosModules.sops
            ];
            _module.args.inputs = inputs;
          };
          shell = ./nixosModules/shell.nix;
          admin = ./nixosModules/admin.nix;
          secrets = { ... }: {
            imports = [
              ./nixosModules/secrets.nix
              inputs.sops-nix.nixosModules.sops
            ];
          };

          aarch64-installer-iso = { modulesPath, lib, pkgs, ... }: {
            imports = [
              "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
            ];
            
            users.users.root.openssh.authorizedKeys.keys = lib.mkDefault [ ];

            environment.systemPackages = with pkgs; [
              git
              htop
              gptfdisk
            ];
          };

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

          spark-base = { ... }: {
            imports = [
              inputs.dgx-spark.nixosModules.dgx-spark
            ];
            nixpkgs.overlays = [
              inputs.dgx-spark.overlays.fixes
            ];
          };

          coordinator = {
            imports = [ ./nixosModules/coordinator.nix ];
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

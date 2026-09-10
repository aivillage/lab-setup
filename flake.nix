{
  description = "lab-setup: Talos homelab utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-kube-generators = {
      url = "github:farcaller/nix-kube-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
      inputs.nixpkgs.follows = "nixpkgs";
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
        ./devShells
        ./checks.nix
        ./packages/inspector
        ./packages/inspector/iso.nix
        ./packages/inspector/netboot.nix
        ./packages/coordinator/package.nix
        ./packages/cluster-cli/package.nix
        ./packages/spark/iso.nix
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

        nixosModules = import ./nixosModules { inherit inputs; };
      };
    };
}

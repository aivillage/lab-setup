{
  description = "Workshop configuration for AIV";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    # For rust
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # For the images and install
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # For generating the talos cilium patch.
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    # For the development environment
    process-compose-flake = {
      url = "github:Platonic-Systems/process-compose-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    services-flake = {
      url = "github:juspay/services-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # For secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, fenix, process-compose-flake, services-flake, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        process-compose-flake.flakeModule
      ];

      # Inspector for the booted computers
      flake.nixosConfigurations.inspector = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
          ./nix/nas/inspector.nix
        ];
      };

      # Nas
      flake.nixosConfigurations.nas = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./nix/nas/configuration.nix
        ];
        
      };

      perSystem = { config, self', pkgs, system, lib, ... }:
        let
          hostSystemName = if (builtins.getEnv "DEV_HOSTNAME") != "" then (builtins.getEnv "DEV_HOSTNAME") else "localhost";
          dev_shell = import ./nix/dev_shell.nix {
            inherit inputs pkgs system hostSystemName;
          };

          rustToolchain = with fenix.packages.${system}; 
          (toolchainOf {
            channel = "1.89.0";
            sha256 = "sha256-+9FmLhAOezBZCOziO0Qct1NOrfpjNsXxc/8I0c7BdKE=";
          }).minimalToolchain;

          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };

          commonBuildInputs = with pkgs; [
            openssl
          ];
          
          commonNativeBuildInputs = with pkgs; [
            pkg-config
            openssl
            cmake
          ];

          binaries = {
            sidecar-bin = rustPlatform.buildRustPackage {
              pname = "workshop-sidecar";
              version = "0.1.0";
              src = ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildInputs = commonBuildInputs;
              nativeBuildInputs = commonNativeBuildInputs;
              buildAndTestSubdir = "crates/sidecar";
              env = {
                LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";
              };
              cargoBuildFlags = [ "-p" "sidecar" ];
              doCheck = false;
              

              meta = with lib; {
                mainProgram = "sidecar";
              };
            };

            hub-bin = rustPlatform.buildRustPackage {
              pname = "workshop-hub";
              version = "0.1.0";
              src = ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildInputs = commonBuildInputs;
              nativeBuildInputs = commonNativeBuildInputs;
              buildAndTestSubdir = "crates/hub";
              env = {
                LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";
              };
              cargoBuildFlags = [ "-p" "hub" ];
              doCheck = false;

              meta = with lib; {
                mainProgram = "hub";
              };
            };

            inspector-bin = rustPlatform.buildRustPackage {
              pname = "inspector";
              version = "0.1.0";
              src = ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildInputs = commonBuildInputs;
              nativeBuildInputs = commonNativeBuildInputs ++ [ pkgs.makeWrapper ];
              buildAndTestSubdir = "crates/inspector";
              env = {
                LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";
              };
              cargoBuildFlags = [ "-p" "inspector" ];
              doCheck = false;

              postInstall = ''
                wrapProgram $out/bin/inspector \
                  --prefix PATH : ${pkgs.lib.makeBinPath [
                    pkgs.util-linux   # lsblk, wipefs, partprobe
                    pkgs.gptfdisk     # sgdisk
                    pkgs.coreutils    # sync
                  ]}
              '';

              meta = with lib; {
                mainProgram = "inspector";
              };
            };

            integration-tests-bin = rustPlatform.buildRustPackage {
              pname = "integration-tests";
              version = "0.1.0";
              src = ./.;
              cargoLock.lockFile = ./Cargo.lock;

              buildInputs = commonBuildInputs;
              nativeBuildInputs = commonNativeBuildInputs;
              buildAndTestSubdir = "crates/integration-tests";
              
              cargoBuildFlags = [ "-p" "integration-tests" ];
              doCheck = false;
              env = {
                LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";
              };

              meta = with lib; {
                mainProgram = "integration-tests";
              };
            };
          };

        in
        {
          process-compose."default" = dev_shell.environment;
          devShells.default = dev_shell.shell;
          devShells."con" = dev_shell.conShell;
          packages = binaries // {
            nas-installer-iso = inputs.nixos-generators.nixosGenerate {
              inherit system;
              format = "install-iso";
              modules = [
                ./nix/nas/iso.nix
              ];
            };
            # Docker Images
            workshop-sidecar = pkgs.dockerTools.buildImage {
              name = "workshop-sidecar";
              tag = "latest";

              config = {
                Cmd = [ "${binaries.sidecar-bin}/bin/sidecar" ];
              };
            };
            
            workshop-hub = pkgs.dockerTools.buildImage {
              name = "workshop-hub";
              tag = "latest";
              
              config = {
                Cmd = [ "${binaries.hub-bin}/bin/hub" ];
              };
            };

            workshop-integration-tests = pkgs.dockerTools.buildImage {
              name = "workshop-integration-tests";
              tag = "latest";
              
              config = {
                Cmd = [ "${binaries.integration-tests-bin}/bin/integration-tests" ];
              };
            };
          };
        };
    };
}
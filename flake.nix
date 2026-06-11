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
          ./packages/inspector.nix
          ./packages/inspector-netboot.nix
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
            apps.default = {
              type = "app";
              program = lib.getExe (
                pkgs.writeShellApplication {
                  name = "start-lab";
                  runtimeInputs = [
                    config.packages.default
                  ];
                  text = ''
                    set -euo pipefail

                    echo "[INFO] Initializing Lab Environment..."

                    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                        DETECTED_ROOT=$(git rev-parse --show-toplevel)
                    else
                        DETECTED_ROOT="$PWD"
                    fi

                    # SET YOUR LAB STORAGE PATH HERE:
                    readonly PROJECT_ROOT="''${PROJECT_ROOT:-$DETECTED_ROOT}"
                    readonly LAB_DATA_DIR="$PROJECT_ROOT/.data"

                    echo "[INFO] Project root resolved to: $PROJECT_ROOT"
                    echo "[INFO] Target lab data directory: $LAB_DATA_DIR"

                    if [[ -d "$LAB_DATA_DIR" ]]; then
                        echo "[INFO] Directory already exists. Skipping creation."
                    else
                        echo "[INFO] Directory not found. Creating '$LAB_DATA_DIR'..."

                        if mkdir -p "$LAB_DATA_DIR"; then
                            echo "[SUCCESS] Data directory created successfully."
                        else
                            echo "[ERROR] Failed to create data directory at '$LAB_DATA_DIR'." >&2
                            echo "[ERROR] Please check your filesystem permissions." >&2
                            exit 1
                        fi
                    fi

                    echo "🚀 Starting lab from root: $LAB_DATA_DIR"
                    (cd "$LAB_DATA_DIR" && ${config.packages.default}/bin/default "$@")

                    echo "📦 Lab Data Storage Summary:"
                    du -chs "$LAB_DATA_DIR"
                  '';
                }
              );
            };
          };

        flake = {
          lib.talos = import ./talos/default.nix {
            inherit inputs;
            lib = inputs.nixpkgs.lib;
          };

          nixosConfigurations = {
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
            iso = import ./head/nas-iso.nix;
          };
        };
      };
}

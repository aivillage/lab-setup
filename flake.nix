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
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      fenix,
      flake-parts,
      ...
    }:
    let
      # Systems the inspector binary can be built for
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forEachSystem =
        systems: f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit system;
          }
        );

      # ── inspector-bin ────────────────────────────────────────
      mkInspectorBin =
        { pkgs, system }:
        let
          rustToolchain = fenix.packages.${system}.stable.minimalToolchain;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
        in
        rustPlatform.buildRustPackage {
          pname = "inspector";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          buildInputs = [ pkgs.openssl ];
          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.openssl
            pkgs.cmake
          ];
          buildAndTestSubdir = "crates/inspector";
          env.LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";
          cargoBuildFlags = [
            "-p"
            "inspector"
          ];
          doCheck = false;
          postInstall = ''
            wrapProgram $out/bin/inspector \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.util-linux
                  pkgs.gptfdisk
                  pkgs.coreutils
                ]
              }
          '';
          meta.mainProgram = "inspector";
        };

    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = supportedSystems;

      imports = [
        inputs.process-compose-flake.flakeModule
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          lib = pkgs.lib;
          dev_shell = import ./dev_shell { inherit inputs pkgs system; };
        in
        {
          process-compose."default" = dev_shell.environment;
          devShells.default = dev_shell.shell;

          packages = {
            inspector-bin = mkInspectorBin { inherit pkgs system; };
          }
          // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            nas-installer-iso =
              (nixpkgs.lib.nixosSystem {
                inherit system;
                specialArgs = { inherit inputs; };
                modules = [ ./head/iso.nix ];
              }).config.system.build.images.iso-installer;
          };

          checks =
            let
              talos = import ./talos/default.nix { inherit pkgs lib inputs; };

              # A minimal fixture machine — used to test structural correctness
              # without needing real hardware config.
              testMachine = talos.machine {
                name = "test-node";
                version = "v1.12.1";
                sha256 = "sha256-5IgKMWkDa4/VkEvD/x7Tr+YebilFJQCk/UoPL7WW1BE=";
                schematicSha256 = "sha256-IU2M1aPO1aKFMDPV2wct734+ZNgid7g0MUDlHgsN6wQ=";
                controlPlane = true;
                network-interfaces = {
                  enp1s0 = {
                    ip = "10.0.0.1";
                    mac = "aa:bb:cc:dd:ee:ff";
                  };
                  enp2s0 = {
                    ip = "10.0.0.2";
                    mac = "11:22:33:44:55:66";
                  };
                };
                diskSelector = {
                  size = 512110190592;
                };
                nvidia = true;
                extraExtensions = [ ];
                extraPatches = [ ];
              };

              generatePatches = talos.mkGeneratePatches {
                nfsServer = "10.0.0.10";
                nfsPath = "/data";
                modelStorePath = "/models";
              };

              # Build the DHCP hosts text and assert expected format.
              dhcpHostsText = lib.concatStringsSep "\n" testMachine.dhcpHosts;

              dhcpHostsCheck = pkgs.runCommand "check-dhcp-hosts" { } ''
                set -euo pipefail
                echo "--- DHCP hosts ---"
                printf '%s\n' ${lib.escapeShellArg dhcpHostsText}

                while IFS= read -r line; do
                  [[ -z "$line" ]] && continue
                  if [[ ! "$line" =~ ^([0-9a-fA-F:]{17}),([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+),(.+)$ ]]; then
                    echo "FAIL: malformed dhcp-host entry: $line"
                    exit 1
                  fi
                done <<< ${lib.escapeShellArg dhcpHostsText}

                count=$(printf '%s\n' ${lib.escapeShellArg dhcpHostsText} | grep -c '.' || true)
                if [[ "$count" -ne 2 ]]; then
                  echo "FAIL: expected 2 dhcp-host entries, got $count"
                  exit 1
                fi

                cp ${pkgs.writeText "dhcp-hosts" dhcpHostsText} $out
                echo "OK: $count dhcp-host entries validated"
              '';

              imageStructureCheck = pkgs.runCommand "check-image-structure" { } ''
                set -euo pipefail

                name="${testMachine.image.name}"
                echo "Image derivation name: $name"
                if [[ "$name" != *"v1.12.1"* ]]; then
                  echo "FAIL: derivation name does not include version"
                  exit 1
                fi
                if [[ "$name" != *"metal-amd64"* ]]; then
                  echo "FAIL: derivation name does not include platform/arch"
                  exit 1
                fi
                name="${testMachine.name}"
                if [[ "$name" != *"test-node"* ]]; then
                  echo "FAIL: derivation name does not have a name"
                  exit 1
                fi

                echo "OK: image derivation structure looks correct"
                echo "$name" > $out
              '';

              machineConfig = testMachine.configScript;

              machineConfigCheck =
                pkgs.runCommand "check-machine-patch"
                  {
                    nativeBuildInputs = [ pkgs.yq-go ];
                  }
                  ''
                    # 1. Execute the patch generator script
                    ${generatePatches}/bin/generate-patches patches/

                    # 2. Execute the machine config generator script
                    ${machineConfig}/bin/generate-config patches/

                    echo "--- Machine patch YAML ---"
                    # 3. Read the file generated by the previous step
                    cat test-node.yaml
                    echo ""

                    # 4. Use yq to test the generated file
                    yq e '.' test-node.yaml > /dev/null

                    hostname=$(yq e '.machine.network.hostname' test-node.yaml)
                    if [[ "$hostname" != "test-node" ]]; then
                      echo "FAIL: expected hostname 'test-node', got '$hostname'"
                      exit 1
                    fi

                    echo "OK: machine patch validated"
                    cp test-node.yaml $out
                  '';

              testMachines = talos.machines {
                control = {
                  version = "v1.12.1";
                  sha256 = "sha256-5IgKMWkDa4/VkEvD/x7Tr+YebilFJQCk/UoPL7WW1BE=";
                  schematicSha256 = "sha256-IU2M1aPO1aKFMDPV2wct734+ZNgid7g0MUDlHgsN6wQ=";
                  controlPlane = true;
                  network-interfaces = {
                    enp1s0 = {
                      ip = "10.0.0.1";
                      mac = "aa:bb:cc:dd:ee:ff";
                    };
                  };
                  diskSelector = {
                    size = 512110190592;
                  };
                };
                worker1 = {
                  version = "v1.12.1";
                  sha256 = "sha256-5IgKMWkDa4/VkEvD/x7Tr+YebilFJQCk/UoPL7WW1BE=";
                  schematicSha256 = "sha256-IU2M1aPO1aKFMDPV2wct734+ZNgid7g0MUDlHgsN6wQ=";
                  controlPlane = false;
                  nvidia = true;
                  network-interfaces = {
                    enp1s0 = {
                      ip = "10.0.0.2";
                      mac = "11:22:33:44:55:66";
                    };
                  };
                  diskSelector = {
                    size = 512110190592;
                  };
                };
              };

              machinesConfigCheck =
                pkgs.runCommand "check-machines-config"
                  {
                    nativeBuildInputs = [ pkgs.yq-go ];
                  }
                  ''
                    # 1. Execute the patch generator script
                    ${generatePatches}/bin/generate-patches patches/

                    # 2. Execute the machines config generator script
                    ${testMachines.generateConfigs}/bin/generate-configs patches/

                    echo "--- Control machine config ---"
                    cat control.yaml | head -n 5
                    echo "--- Worker1 machine config ---"
                    cat worker1.yaml | head -n 5

                    # 3. Use yq to test the generated files
                    [[ $(yq e '.machine.network.hostname' control.yaml) == "control" ]]
                    [[ $(yq e '.machine.network.hostname' worker1.yaml) == "worker1" ]]

                    echo "OK: machines group config validated"
                    touch $out
                  '';
            in
            {
              talos-generate-patches = generatePatches;
              talos-dhcp-hosts = dhcpHostsCheck;
              talos-image-structure = imageStructureCheck;
              talos-machine-image = testMachine.image;
              talos-machine-patch = machineConfigCheck;
              talos-machines-config = machinesConfigCheck;
            };

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

        nixosConfigurations.inspector = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit inputs;
            inspectorBin = mkInspectorBin {
              pkgs = nixpkgs.legacyPackages."x86_64-linux";
              system = "x86_64-linux";
            };
          };
          modules = [
            (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
            ./head/inspector.nix
          ];
        };

        nixosModules = {
          pxe =
            { ... }:
            {
              imports = [ ./head/default.nix ];
              _module.args.inspector = self.nixosConfigurations.inspector;
            };
          iso = import ./head/iso.nix;
        };
      };
    };
}

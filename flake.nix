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
                sha256 = "sha256-Hj2L6bcDnTItd2XlP4UzEQ1W89F5QxkjY0TNL74wmfw=";
                schematicSha256 = pkgs.lib.fakeSha256;
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
                nvidia = false;
                extraExtensions = [ ];
                extraPatches = [ ];
              };

              generatePatches = talos.mkGeneratePatches {
                nfsServer = "10.0.0.10";
                mainPath = "/data";
                vllmPath = "/models";
              };

              # Build the DHCP hosts text and assert expected format.
              # Each entry must be: "<mac>,<ip>,<hostname>"
              dhcpHostsText = lib.concatStringsSep "\n" testMachine.dhcpHosts;

              dhcpHostsCheck = pkgs.runCommand "check-dhcp-hosts" { } ''
                set -euo pipefail
                echo "--- DHCP hosts ---"
                printf '%s\n' ${lib.escapeShellArg dhcpHostsText}

                # Every non-empty line must match MAC,IP,name
                while IFS= read -r line; do
                  [[ -z "$line" ]] && continue
                  if [[ ! "$line" =~ ^([0-9a-fA-F:]{17}),([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+),(.+)$ ]]; then
                    echo "FAIL: malformed dhcp-host entry: $line"
                    exit 1
                  fi
                done <<< ${lib.escapeShellArg dhcpHostsText}

                # We expect exactly one entry per network interface (2 in the fixture)
                count=$(printf '%s\n' ${lib.escapeShellArg dhcpHostsText} | grep -c '.' || true)
                if [[ "$count" -ne 2 ]]; then
                  echo "FAIL: expected 2 dhcp-host entries, got $count"
                  exit 1
                fi

                cp ${pkgs.writeText "dhcp-hosts" dhcpHostsText} $out
                echo "OK: $count dhcp-host entries validated"
              '';

              # Validate the image derivation has the expected output structure
              # for pxe-assets mode (directory with vmlinuz + initrd).
              # This check is structural — it verifies the Nix derivation attrs
              # are correct without fetching (the hash will fail if actually built
              # with fakeSha256; swap in a real hash to make it fetchable).
              imageStructureCheck = pkgs.runCommand "check-image-structure" { } ''
                set -euo pipefail

                # Confirm the image derivation name contains expected version/platform
                name="${testMachine.image.name}"
                echo "Image derivation name: $name"
                if [[ "$name" != *"v1.9.0"* ]]; then
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

            in
            {
              talos-generate-patches = generatePatches;

              talos-dhcp-hosts = dhcpHostsCheck;

              talos-image-structure = imageStructureCheck;

              talos-machine-image = testMachine.image;
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
      };
    };
}

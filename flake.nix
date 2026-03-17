{
  description = "lab-setup: Talos homelab utilities";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-kube-generators.url = "github:farcaller/nix-kube-generators";

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
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
      nixos-generators,
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
            nas-installer-iso = nixos-generators.nixosGenerate {
              inherit system;
              format = "install-iso";
              specialArgs = { inherit inputs; };
              modules = [ ./head/iso.nix ];
            };
          };

          checks =
            let
              talos = import ./talos/default.nix { inherit pkgs lib inputs; };

              fixtureMachine = talos.mkMachine {
                name = "test-node";
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
                nvidia = false;
                extraExtensions = [ ];
                extraPatches = [ ];
              };

              testMachine = talos.mkMachine {
                machine = fixtureMachine;
                version = "v1.9.0";
                sha256 = lib.fakeSha256; # or a real one
              };

              generatePatches = talos.mkGeneratePatches {
                nfsServer = "10.0.0.10";
                mainPath = "/data";
                vllmPath = "/models";
              };
            in
            {
              # This forces Nix to actually build the derivations
              talos-generate-patches = generatePatches;
              talos-machine-image = testMachine.image;
              talos-dhcp-hosts = pkgs.writeText "dhcp-hosts" (lib.concatStringsSep "\n" testMachine.dhcpHosts);
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

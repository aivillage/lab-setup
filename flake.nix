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

              machinePatch = talos.mkMachinePatch testMachine.machine;

              machinePatchCheck =
                pkgs.runCommand "check-machine-patch"
                  {
                    nativeBuildInputs = [ pkgs.yq-go ];
                  }
                  ''
                    set -euo pipefail

                    echo "--- Machine patch YAML ---"
                    cat ${machinePatch}
                    echo ""

                    # Must be valid YAML
                    yq e '.' ${machinePatch} > /dev/null

                    # Hostname
                    hostname=$(yq e '.machine.network.hostname' ${machinePatch})
                    if [[ "$hostname" != "test-node" ]]; then
                      echo "FAIL: expected hostname 'test-node', got '$hostname'"
                      exit 1
                    fi

                    # Interfaces — expect 2
                    iface_count=$(yq e '.machine.network.interfaces | length' ${machinePatch})
                    if [[ "$iface_count" -ne 2 ]]; then
                      echo "FAIL: expected 2 interfaces, got $iface_count"
                      exit 1
                    fi

                    # Each interface must have dhcp: false and at least one address
                    for i in $(seq 0 $((iface_count - 1))); do
                      dhcp=$(yq e ".machine.network.interfaces[$i].dhcp" ${machinePatch})
                      if [[ "$dhcp" != "false" ]]; then
                        echo "FAIL: interface $i has dhcp=$dhcp, expected false"
                        exit 1
                      fi
                      addr_count=$(yq e ".machine.network.interfaces[$i].addresses | length" ${machinePatch})
                      if [[ "$addr_count" -lt 1 ]]; then
                        echo "FAIL: interface $i has no addresses"
                        exit 1
                      fi
                    done

                    # Install — wipe must be true, disk must be null
                    wipe=$(yq e '.machine.install.wipe' ${machinePatch})
                    if [[ "$wipe" != "true" ]]; then
                      echo "FAIL: install.wipe is '$wipe', expected 'true'"
                      exit 1
                    fi
                    disk=$(yq e '.machine.install.disk' ${machinePatch})
                    if [[ "$disk" != "null" ]]; then
                      echo "FAIL: install.disk is '$disk', expected 'null'"
                      exit 1
                    fi

                    # diskSelector.size must be present and numeric
                    ds_size=$(yq e '.machine.install.diskSelector.size' ${machinePatch})
                    if [[ "$ds_size" != "512110190592" ]]; then
                      echo "FAIL: diskSelector.size is '$ds_size', expected '512110190592'"
                      exit 1
                    fi

                    echo "OK: machine patch validated"
                    cp ${machinePatch} $out
                  '';

              # ── Helm / shared patch YAML checks ──────────────────
              #
              # Build every shared patch derivation and validate:
              #   1. Valid YAML
              #   2. Has the expected top-level Talos config key
              #      (cluster.inlineManifests or machine.*)
              #   3. inlineManifests entries have name + contents
              #
              kubelib = inputs.nix-kube-generators.lib { inherit pkgs; };

              ciliumPatch = import ./talos/patches/cilium.nix { inherit pkgs kubelib; };
              nvidiaPatch = (import ./talos/patches/nvidia.nix { inherit pkgs kubelib; });
              nfsPatch = import ./talos/patches/nfs.nix {
                inherit pkgs kubelib;
                server = "10.0.0.10";
                path = "/data";
              };
              modelStorePatch = import ./talos/patches/model-store.nix {
                inherit pkgs kubelib;
                server = "10.0.0.10";
                path = "/models";
                name = "model-store";
              };

              # Helper: validate a Talos patch file that wraps a helm chart
              # as cluster.inlineManifests
              mkHelmPatchCheck =
                name: patchFile: expectedManifestName:
                pkgs.runCommand "check-helm-patch-${name}"
                  {
                    nativeBuildInputs = [ pkgs.yq-go ];
                  }
                  ''
                    set -euo pipefail

                    echo "--- Checking ${name} patch ---"

                    # 1. Must be valid YAML
                    yq e '.' ${patchFile} > /dev/null || {
                      echo "FAIL: ${name} is not valid YAML"; exit 1;
                    }

                    # 2. Must have cluster.inlineManifests
                    manifest_count=$(yq e '.cluster.inlineManifests | length' ${patchFile})
                    if [[ "$manifest_count" -lt 1 ]]; then
                      echo "FAIL: ${name} has no cluster.inlineManifests entries"
                      exit 1
                    fi

                    # 3. Must contain an entry with the expected name
                    found=$(yq e '.cluster.inlineManifests[] | select(.name == "${expectedManifestName}") | .name' ${patchFile})
                    if [[ -z "$found" ]]; then
                      echo "FAIL: ${name} missing inlineManifest named '${expectedManifestName}'"
                      exit 1
                    fi

                    # 4. That entry's contents must be non-empty
                    contents=$(yq e '.cluster.inlineManifests[] | select(.name == "${expectedManifestName}") | .contents' ${patchFile})
                    if [[ -z "$contents" || "$contents" == "null" ]]; then
                      echo "FAIL: ${name} '${expectedManifestName}' has empty contents"
                      exit 1
                    fi

                    echo "OK: ${name} patch validated (manifest: ${expectedManifestName})"
                    cp ${patchFile} $out
                  '';

              # Nvidia kernel modules patch is machine.* not cluster.*
              nvidiaKernelCheck =
                pkgs.runCommand "check-nvidia-kernel-patch"
                  {
                    nativeBuildInputs = [ pkgs.yq-go ];
                  }
                  ''
                    set -euo pipefail

                    echo "--- Checking nvidia kernel modules patch ---"
                    yq e '.' ${nvidiaPatch.kernelModulesPatch} > /dev/null

                    module_count=$(yq e '.machine.kernel.modules | length' ${nvidiaPatch.kernelModulesPatch})
                    if [[ "$module_count" -lt 4 ]]; then
                      echo "FAIL: expected at least 4 nvidia kernel modules, got $module_count"
                      exit 1
                    fi

                    echo "OK: nvidia kernel patch validated ($module_count modules)"
                    cp ${nvidiaPatch.kernelModulesPatch} $out
                  '';
            in
            {
              talos-generate-patches = generatePatches;

              talos-dhcp-hosts = dhcpHostsCheck;

              talos-image-structure = imageStructureCheck;

              talos-machine-image = testMachine.image;
              talos-patch-cilium = mkHelmPatchCheck "cilium" ciliumPatch "cilium";
              talos-patch-nvidia-helm = mkHelmPatchCheck "nvidia" nvidiaPatch.helmPatch "nvidia-device-plugin";
              talos-patch-nvidia-kernel = nvidiaKernelCheck;
              talos-patch-nfs = mkHelmPatchCheck "nfs" nfsPatch "nfs-provisioner";
              talos-patch-model-store = mkHelmPatchCheck "model-store" modelStorePatch "model-store";
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

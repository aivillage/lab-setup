{
  inputs,
  pkgs,
  system,
  ...
}:
let
  inherit (inputs.services-flake.lib) multiService;
  inherit (inputs) fenix;
  inherit (inputs) nix-kube-generators;
  inherit (pkgs) lib;
  kubelib = nix-kube-generators.lib { inherit pkgs; };

  rustToolchain = fenix.packages.${system}.stable.toolchain;

  cliTools =
    with pkgs;
    [
      curl
      talosctl
      kubectl
      kubernetes-helm
      tilt
      openssl
      zsh
      k9s
      cilium-cli
      hubble
      sops
      ssh-to-age
    ]
    ++ [
      rustToolchain
    ];

  aivLabSettings = (import ./settings.nix { inherit pkgs; }).aiv-lab;

  isDarwin = pkgs.stdenv.isDarwin;

in
{
  shell = pkgs.mkShell {
    name = "aiv-k8-dev";

    # The packages available in the development environment
    packages = cliTools;

    # Setup hook that prepares environment and config files
    shellHook = ''
      ${
        if isDarwin then
          ''
            # macOS-specific configuration
            unset DEVELOPER_DIR
          ''
        else
          ""
      }

      # Set up environment variables

      # services-flake defaults to $PWD, so we set our scripts to match
      export PROJECT_ROOT=$PWD
      # DATA_DIR == baseDataDir in settings.nix
      export DATA_DIR="$PROJECT_ROOT"

      if [ -f .envhost ]; then
        set -a
        source .envhost
        set +a
        if [ -n "$GITHUB_USERNAME" ] && [ -n "$GHCR_PAT" ]; then
          echo "Logging into ghcr.io..."
          echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
        fi
      fi
      # Todo: move this elsewhere
      export TALOS_VERSION="v1.13.3"
      export KUBECONFIG="$DATA_DIR/${aivLabSettings.talos.storagePath}/kubeconfig"
      export TALOSCONFIG="$DATA_DIR/${aivLabSettings.talos.storagePath}/talosconfig"
      export TALOS_STATE_DIR="$DATA_DIR/talos"
      export DIRENV_WARN_TIMEOUT=0
      export TF_DATA_DIR="$PROJECT_ROOT/${aivLabSettings.baseDataDir}/terraform"
      export TF_VAR_kubeconfig="$KUBECONFIG"
      export MC_CONFIG_DIR="$PROJECT_ROOT/${aivLabSettings.baseDataDir}/minio"
      export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}:$LD_LIBRARY_PATH"
    '';
  };

  conShell = pkgs.mkShell {
    name = "aiv-k8-dev";

    # The packages available in the development environment
    packages = cliTools;

    # Setup hook that prepares environment and config files
    shellHook = ''
      ${
        if isDarwin then
          ''
            # macOS-specific configuration
            unset DEVELOPER_DIR
          ''
        else
          ""
      }

      # Set up environment variables
      export PROJECT_ROOT=$PWD
      export DEPLOYMENT_DIR="$PROJECT_ROOT/deployment"

      if [ -f .envhost ]; then
        set -a
        source .envhost
        set +a
        if [ -n "$GITHUB_USERNAME" ] && [ -n "$GHCR_PAT" ]; then
          echo "Logging into ghcr.io..."
          echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
        fi
      fi
      # Todo: move this elsewhere
      export TALOS_VERSION="v1.13.3"
      export KUBECONFIG="$DEPLOYMENT_DIR/talos/kubeconfig"
      export TALOSCONFIG="$DEPLOYMENT_DIR/talos/talosconfig"
      export TALOS_STATE_DIR="$DEPLOYMENT_DIR/talos"
      export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}:$LD_LIBRARY_PATH"
    '';
  };

  environment = {
    imports = [
      inputs.services-flake.processComposeModules.default
      (multiService ./tilt.nix)
      (multiService ./local_path_storage.nix)
      (multiService ./talos.nix)
      (multiService ./patches.nix)
      (multiService ./containers.nix)
    ];

    services =
      let
        # hacky
        provisionerType = "docker";
        webserver = true;
        registries = true;
      in
      {
        # look in ./containers.nix for options
        containers."lab" = {
          enable = true;
          webserver = lib.mkIf webserver {
            enable = true;
            localPort = aivLabSettings.webserver.port;
            bindMounts = [
              "${aivLabSettings.patches.storagePath}:/usr/share/nginx/html/patches:ro"
            ];
          };
          registries = lib.mkIf registries {
            enable = registries;
            providers = {
              docker = {
                remoteUrl = "https://registry-1.docker.io";
                localPort = 5000;
              };
              k8s = {
                remoteUrl = "https://registry.k8s.io";
                localPort = 5001;
              };
              gcr = {
                remoteUrl = "https://gcr.io";
                localPort = 5002;
              };
              ghcr = {
                remoteUrl = "https://ghcr.io";
                localPort = 5003;
              };
              quay = {
                remoteUrl = "https://quay.io";
                localPort = 5004;
              };
            };
          };
        };

        patches."patch0" = {
          enable = true;
          dataDir = aivLabSettings.patches.storagePath;
          kubelib = kubelib;
        };

        # look in ./talos.nix for options
        talos = {
          cluster = {
            enable = true;
            dataDir = aivLabSettings.talos.storagePath;
            provisioner = provisionerType;
            workers = {
              count = 3;
              cpus = "2.0";
              memory = "2Gib";
            };
            registryMirrors = lib.mkIf registries [
              "docker.io=http://${aivLabSettings.host}:5000"
              "registry.k8s.io=http://${aivLabSettings.host}:5001"
              "gcr.io=http://${aivLabSettings.host}:5002"
              "ghcr.io=http://${aivLabSettings.host}:5003"
              "quay.io=http://${aivLabSettings.host}:5004"
            ];
            # This is defined in the .envrc. These can't be paths as they're not checked in.
            configPatches = [
              # bootstrap patch applied via patches.nix for now
              # "${aivLabSettings.baseDataDir}/talos-patches/cilium.yaml"
              # "${aivLabSettings.baseDataDir}/talos-patches/ghcr.yaml"
            ];
          }
          // lib.optionalAttrs (provisionerType == "docker") {
            docker = {
              exposedPorts = "80:80/tcp,443:443/tcp";
            };
          }
          // lib.optionalAttrs (provisionerType == "qemu") {
            qemu = {
              presets = [ "iso" ];
            };
          };
        };

        local_path_storage."storage" = {
          enable = false;
          kubeconfig = "${aivLabSettings.baseDataDir}/talos/kubeconfig";
        };

        tilt = {
          tilt = {
            enable = false;
            dataDir = "${aivLabSettings.baseDataDir}/postgres";
            runtimeInputs = [ ];
            environment = {
              KUBECONFIG = "${aivLabSettings.baseDataDir}/talos/kubeconfig";
              NIX_CONFIG = "experimental-features = nix-command flakes";
              NIX_PATH = "nixpkgs=${pkgs.path}";
            };
          };
        };
      };

    settings.processes = {
      cluster.depends_on = {
        patch0.condition = "process_completed_successfully";
        "registry-docker" = {
          condition = "process_started";
        };
        "registry-k8s" = {
          condition = "process_started";
        };
        "registry-gcr" = {
          condition = "process_started";
        };
        "registry-ghcr" = {
          condition = "process_started";
        };
        "webserver-talos-patches" = {
          condition = "process_started";
        };
      };

      # todo
      # storage.depends_on = {
      #   cluster.condition = "process_log_ready";
      # };
      #
      # tilt.depends_on = {
      #   storage.condition = "process_completed_successfully";
      #   cluster.condition = "process_log_ready";
      # };
    };
  };
}

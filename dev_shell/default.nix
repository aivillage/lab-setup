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
  kubelib = nix-kube-generators.lib { inherit pkgs; };

  rustToolchain = fenix.packages.${system}.stable.toolchain;

  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;

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
      export PROJECT_ROOT=$PWD
      export DATA_DIR="$PROJECT_ROOT/.data"

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
      export TALOS_VERSION="v1.11.0"
      export KUBECONFIG="$DATA_DIR/talos/kubeconfig"
      export TALOSCONFIG="$DATA_DIR/talos/talosconfig"
      export TALOS_STATE_DIR="$DATA_DIR/talos"
      export DIRENV_WARN_TIMEOUT=0
      export TF_DATA_DIR="$PROJECT_ROOT/.data/terraform"
      export TF_VAR_kubeconfig="$KUBECONFIG"
      export MC_CONFIG_DIR="$PROJECT_ROOT/.data/minio"
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
      export TALOS_VERSION="v1.12.1"
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
      (multiService ./container_repository.nix)
    ];

    services = {
      container_repository = {
        docker = {
          enable = true;
          remoteUrl = "https://registry-1.docker.io";
          dataDir = ".data/repo/docker";
          localPort = 5000;
        };
        k8s = {
          enable = true;
          remoteUrl = "https://registry.k8s.io";
          dataDir = ".data/repo/k8s";
          localPort = 5001;
        };
        gcr = {
          enable = true;
          remoteUrl = "https://gcr.io";
          dataDir = ".data/repo/gcr";
          localPort = 5002;
        };
        ghcr = {
          enable = true;
          remoteUrl = "https://ghcr.io";
          dataDir = ".data/repo/ghcr";
          localPort = 5003;
        };
        quay = {
          enable = true;
          remoteUrl = "https://quay.io";
          dataDir = ".data/repo/quay";
          localPort = 5004;
        };
      };

      patches."patch0" = {
        enable = true;
        dataDir = ".data/talos-patches";
        kubelib = kubelib;
      };

      talos = {
        cluster = {
          enable = true;
          useSudo = true;
          dataDir = ".data/talos";
          controlplanes = 1;
          cpus = "4.0";
          memory = 8192;
          workers = 3;
          cpusWorkers = "4.0";
          memoryWorkers = 12188;
          disk = 24376;
          # extra-disks = 2;
          # extra-disks-size = 8192;
          provisioner = "qemu";
          registryMirrors = [
            "docker.io=http://10.5.0.1:5000"
            "registry.k8s.io=http://10.5.0.1:5001"
            "gcr.io=http://10.5.0.1:5002"
            "ghcr.io=http://10.5.0.1:5003"
            "quay.io=http://10.5.0.1:5004"
          ];
          # This is defined in the .envrc. These can't be paths as they're not checked in.
          configPatches = [
            ".data/talos-patches/cilium.yaml"
            ".data/talos-patches/ghcr.yaml"
          ];
        };
      };

      local_path_storage."storage" = {
        enable = true;
        kubeconfig = ".data/talos/kubeconfig";
      };

      tilt = {
        tilt = {
          enable = true;
          dataDir = ".data/postgres";
          runtimeInputs = [ ];
          environment = {
            KUBECONFIG = ".data/talos/kubeconfig";
            NIX_CONFIG = "experimental-features = nix-command flakes";
            NIX_PATH = "nixpkgs=${pkgs.path}";
          };
        };
      };
    };

    settings.processes.cluster.depends_on = {
      docker.condition = "process_started";
      k8s.condition = "process_started";
      gcr.condition = "process_started";
      ghcr.condition = "process_started";
      patch0.condition = "process_completed_successfully";
    };
    settings.processes.storage.depends_on = {
      cluster.condition = "process_log_ready";
    };
    settings.processes.tilt.depends_on = {
      storage.condition = "process_completed_successfully";
      cluster.condition = "process_log_ready";
    };
  };
}

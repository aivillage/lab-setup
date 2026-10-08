{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      config,
      ...
    }:
    let
      inherit (inputs) fenix;

      talos = import ../talos { inherit pkgs inputs; lib = pkgs.lib; };
      generatePatches = talos.mkGeneratePatches {
        coordinatorIp = "127.0.0.1";
        webserverHost = "http://host.docker.internal:5555";
      };

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
          config.packages.cluster-cli
          generatePatches
        ];

      isDarwin = pkgs.stdenv.isDarwin;

    in
    {
      devShells = {
        default = pkgs.mkShell {
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
            export DATA_DIR="$PROJECT_ROOT"

            if [ -f .envhost ]; then
              set -a
              source .envhost
              set +a
              if [ -n "$GITHUB_USERNAME" ] && [ -n "$GHCR_PAT" ]; then
                echo "Logging into ghcr.io..."
                ENGINE=$(command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo "")
                if [ -n "$ENGINE" ]; then
                  echo "$GHCR_PAT" | "$ENGINE" login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
                fi
              fi
            fi

            if [ -z "''${DOCKER_HOST:-}" ]; then
              if [ -S "/var/run/docker.sock" ]; then
                export DOCKER_HOST="unix:///var/run/docker.sock"
              elif [ -S "$HOME/.docker/run/docker.sock" ]; then
                export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
              elif [ -S "$HOME/.local/share/containers/podman/machine/podman.sock" ]; then
                export DOCKER_HOST="unix://$HOME/.local/share/containers/podman/machine/podman.sock"
              elif command -v podman >/dev/null 2>&1; then
                PODMAN_SOCK=$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || echo "")
                if [ -n "$PODMAN_SOCK" ] && [ -S "$PODMAN_SOCK" ]; then
                  export DOCKER_HOST="unix://$PODMAN_SOCK"
                fi
              fi
            fi

            export TALOS_VERSION="v1.13.3"
            export KUBECONFIG="$DATA_DIR/.cluster/k8s/kubeconfig"
            export TALOSCONFIG="$DATA_DIR/.cluster/talos/talosconfig"
            export TALOS_STATE_DIR="$DATA_DIR/.cluster/talos"
            export DIRENV_WARN_TIMEOUT=0
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}:$LD_LIBRARY_PATH"
          '';
        };

        inspector = pkgs.mkShell {
          name = "aiv-inspector-dev";
          packages = [
            rustToolchain
            pkgs.rust-analyzer
            pkgs.clippy
            pkgs.pkg-config
            pkgs.openssl
          ];
          shellHook = ''
            export RUST_BACKTRACE=1
          '';
        };
      };
    };
}

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
                echo "$GHCR_PAT" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
              fi
            fi
            # Todo: move this elsewhere
            export TALOS_VERSION="v1.13.3"
            export KUBECONFIG="$DATA_DIR/${config.process-compose.default.services.talos.cluster.dataDir}/kubeconfig"
            export TALOSCONFIG="$DATA_DIR/${config.process-compose.default.services.talos.cluster.dataDir}/talosconfig"
            export TALOS_STATE_DIR="$DATA_DIR/talos"
            export DIRENV_WARN_TIMEOUT=0
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
      };
    };
}

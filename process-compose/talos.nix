{
  config,
  lib,
  name,
  pkgs,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    mkPackageOption
    mkIf
    ;

  cfg = config;

  KUBECONFIG = config.dataDir + "kubeconfig";
  TALOSCONFIG = config.dataDir + "talosconfig";

  startCommandArgs =
    let
      arg = lib.escapeShellArg;
      argStr = x: lib.escapeShellArg (toString x);

      baseArgs =
        lib.optionals config.qemu.useSudo [
          "sudo"
        ]
        ++ [
          (lib.getExe config.package)
          "cluster"
          "create"
          (arg config.provisioner)
          "--name"
          (arg config.clusterName)
          "--state"
          (arg "${cfg.dataDir}")
          "--talosconfig-destination"
          (arg TALOSCONFIG)
          "--workers"
          (argStr config.workers.count)
          "--cpus-workers"
          (arg config.workers.cpus)
          "--memory-workers"
          (argStr config.workers.memory)
          "--cpus-controlplanes"
          (argStr config.controlplanes.cpus)
          "--memory-controlplanes"
          (argStr config.controlplanes.memory)
        ]
        ++ lib.optional config.withDebug "--with-debug"
        ++ lib.optional config.withKubespan "--with-kubespan"
        ++ lib.concatMap (mirror: [
          "--registry-mirror"
          mirror
        ]) config.registryMirrors
        ++ lib.concatMap (patch: [
          "--config-patch"
          "@${patch}"
        ]) config.configPatches;

      dockerArgs = lib.optionals (config.provisioner == "docker") (
        lib.optionals (config.docker.image != null) [
          "--image"
          (arg config.docker.image)
        ]
        ++ lib.optionals (config.docker.exposedPorts != null) [
          "--exposed-ports"
          (arg config.docker.exposedPorts)
        ]
      );

      qemuArgs =
        let
          allDisks = lib.concatStringsSep "," (map (d: "${d.driver}:${d.size}") config.qemu.disks);
        in
        lib.optionals (config.provisioner == "qemu") (
          [
            "--presets"
            (arg config.qemu.presets)
            "--disks"
            (arg allDisks)
          ]
          ++ lib.optionals (config.qemu.cidr != null) [
            "--cidr"
            (arg config.qemu.cidr)
          ]
          ++ lib.optionals (config.qemu.controlplanes != null) [
            "--controlplanes"
            (argStr config.qemu.controlplanes.count)
          ]
        );

    in
    baseArgs ++ dockerArgs ++ qemuArgs;

  # Main start script for the Talos cluster
  startScript = pkgs.writeShellApplication {
    name = "start-talos";
    runtimeInputs = with pkgs; [
      config.package
      coreutils
    ];
    text = ''
      set -euo pipefail

      ${lib.optionalString config.qemu.useSudo ''
        # Check if sudo requires a password
        if ! sudo -n true 2>/dev/null; then
            echo "[ERROR]: sudo requires a password."
            echo "Please authorize sudo session:"
            echo "$ sudo -v"
            exit 1
        fi
        echo "Sudo does not require a password. Proceeding..."
      ''}

      # Auto-detect container engine socket if DOCKER_HOST is unset
      if [ -z "''${DOCKER_HOST:-}" ]; then
        if [ -S "/var/run/docker.sock" ]; then
          export DOCKER_HOST="unix:///var/run/docker.sock"
        elif [ -n "''${HOME:-}" ] && [ -S "$HOME/.docker/run/docker.sock" ]; then
          export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
        elif [ -n "''${HOME:-}" ] && [ -S "$HOME/.local/share/containers/podman/machine/podman.sock" ]; then
          export DOCKER_HOST="unix://$HOME/.local/share/containers/podman/machine/podman.sock"
        else
          # On macOS, check temporary folders for active Podman machine API socket
          PODMAN_API_SOCK=$(/bin/sh -c 'ls /var/folders/*/*/*/podman/*-api.sock 2>/dev/null | head -n 1' || echo "")
          if [ -n "$PODMAN_API_SOCK" ] && [ -S "$PODMAN_API_SOCK" ]; then
            export DOCKER_HOST="unix://$PODMAN_API_SOCK"
          else
            PODMAN_BIN=$(command -v podman 2>/dev/null || echo "/opt/homebrew/bin/podman")
            if [ -x "$PODMAN_BIN" ]; then
              PODMAN_SOCK=$("$PODMAN_BIN" machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || "$PODMAN_BIN" info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || echo "")
              if [ -n "$PODMAN_SOCK" ] && [ -S "$PODMAN_SOCK" ]; then
                export DOCKER_HOST="unix://$PODMAN_SOCK"
              fi
            fi
          fi
        fi
      fi

      # Create required directories
      echo "Creating the following directory: $PWD/${config.dataDir}"
      mkdir -p "${config.dataDir}"

      echo "Starting ${config.provisioner} based Talos cluster '${config.clusterName}'..."

      echo "Executing: ${(lib.concatStringsSep " " startCommandArgs)}"
      ${(lib.concatStringsSep " " startCommandArgs)}

      # Fix permissions if running with sudo
      ${lib.optionalString config.qemu.useSudo ''
        if [ -f "${TALOSCONFIG}" ]; then
          sudo chown "$USER":"$USER" "${TALOSCONFIG}"
        fi
        if [ -f "${KUBECONFIG}" ]; then
          sudo chown "$USER":"$USER" "${KUBECONFIG}"
        fi
      ''}

      # Run post-start hook if provided
      ${lib.optionalString (config.postStartHook != null) config.postStartHook}

      echo "Talos cluster '${config.clusterName}' started successfully"
    '';
  };

  # Cleanup script for destroying the cluster
  cleanupScript = ''
    # Don't exit on error during cleanup
    set +e

    if [ -z "''${DOCKER_HOST:-}" ]; then
      if [ -S "/var/run/docker.sock" ]; then
        export DOCKER_HOST="unix:///var/run/docker.sock"
      elif [ -n "''${HOME:-}" ] && [ -S "$HOME/.docker/run/docker.sock" ]; then
        export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
      elif [ -n "''${HOME:-}" ] && [ -S "$HOME/.local/share/containers/podman/machine/podman.sock" ]; then
        export DOCKER_HOST="unix://$HOME/.local/share/containers/podman/machine/podman.sock"
      else
        # On macOS, check temporary folders for active Podman machine API socket
        PODMAN_API_SOCK=$(/bin/sh -c 'ls /var/folders/*/*/*/podman/*-api.sock 2>/dev/null | head -n 1' || echo "")
        if [ -n "$PODMAN_API_SOCK" ] && [ -S "$PODMAN_API_SOCK" ]; then
          export DOCKER_HOST="unix://$PODMAN_API_SOCK"
        else
          PODMAN_BIN=$(command -v podman 2>/dev/null || echo "/opt/homebrew/bin/podman")
          if [ -x "$PODMAN_BIN" ]; then
            PODMAN_SOCK=$("$PODMAN_BIN" machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || "$PODMAN_BIN" info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || echo "")
            if [ -n "$PODMAN_SOCK" ] && [ -S "$PODMAN_SOCK" ]; then
              export DOCKER_HOST="unix://$PODMAN_SOCK"
            fi
          fi
        fi
      fi
    fi

    echo "Destroying Talos cluster '${config.clusterName}'..."

    # Run pre-stop hook if provided
    ${lib.optionalString (config.preStopHook != null) config.preStopHook}

    if [ -d "${config.dataDir}" ]; then
      CMD="${
        if config.qemu.useSudo then "sudo -E " else ""
      }${lib.getExe config.package} cluster destroy"
      CMD="$CMD --name ${config.clusterName}"
      CMD="$CMD --state ${config.dataDir}"
      CMD="$CMD --provisioner ${config.provisioner}"

      echo "Executing: $CMD"
      eval "$CMD" 2>/dev/null || {
        echo "Warning: Failed to destroy cluster normally, attempting force cleanup..."
        rm -rf "${config.dataDir}/${(lib.escapeShellArg config.clusterName)}"
      }
    fi

    # Clean up config files
    rm -f "${TALOSCONFIG}" 2>/dev/null || true
    rm -f "${KUBECONFIG}" 2>/dev/null || true

    echo "Talos cluster '${config.clusterName}' destroyed"
  '';

  # Health check script
  healthCheckScript = pkgs.writeShellApplication {
    name = "check-talos";
    runtimeInputs = [
      config.package
      pkgs.kubectl
    ];
    text = ''
      # Check if we can connect to Talos API
      ${lib.getExe config.package} --talosconfig "${TALOSCONFIG}" \
        cluster show --name "${config.clusterName}" >/dev/null 2>&1 || exit 1

      # If kubectl check is enabled, verify k8s connectivity
      ${lib.optionalString config.checkKubectl ''
        export KUBECONFIG="${KUBECONFIG}"
        kubectl get nodes >/dev/null 2>&1 || exit 1
      ''}

      exit 0
    '';
  };
in
{
  options = {
    package = mkPackageOption pkgs "talosctl" { };

    talosVersion = mkOption {
      type = types.str;
      default = "v1.13.3";
      description = "Talos version to use.";
    };

    clusterName = mkOption {
      type = types.str;
      default = "talos-local";
      description = "Name of the Talos cluster.";
    };

    controlplanes = {
      cpus = mkOption {
        type = types.str;
        default = "2.0";
        description = "CPU allocation for control plane node.";
      };
      memory = mkOption {
        type = types.str;
        default = "2Gib";
        description = "string(mb,gb) the limit on memory usage for the controlplanes (default 2.0GiB)";
      };
    };

    workers = {
      count = mkOption {
        type = types.int;
        default = 1;
        description = "Number of worker nodes.";
      };
      cpus = mkOption {
        type = types.str;
        default = "2.0";
        description = "CPU allocation for worker nodes.";
      };
      memory = mkOption {
        type = types.str;
        default = "2Gib";
        description = "string(mb,gb) the limit on memory usage for each worker/VM (default 2.0GiB)";
      };
    };

    provisioner = mkOption {
      type = types.enum [
        "docker"
        "qemu"
      ];
      default = "docker";
      description = "Provisioner to use for the cluster.";
    };

    docker = {
      image = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Docker image to use (docker provisioner only).";
      };

      exposedPorts = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          comma-separated list of ports/protocols to expose on init node.
          "80:80/tcp,443:443/tcp"
        '';
      };
    };

    qemu = {
      presets = mkOption {
        type = types.listOf (
          types.enum [
            "pxe" # wip
            "iso"
            "iso-secureboot" # wip
          ]
        );
        default = [ "iso" ];
        description = ''
          talosctl cluster create qemu --help
            Available presets:
              - iso: Configure Talos to boot from an ISO from the Image Factory.
              - iso-secureboot: Configure Talos for Secureboot via ISO. Only available on Linux hosts.
              - pxe: Configure Talos to boot via PXE from the Image Factory.
        '';
      };

      useSudo = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Use sudo for talosctl commands.
             Requires an active sudo session. Run 'sudo -v' before executing this script to cache credentials.
        '';
      };

      cidr = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CIDR of the cluster network.";
      };

      controlplanes.count = mkOption {
        type = types.int;
        default = 1;
        description = "Number of controlplanes nodes.";
      };

      disks = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              driver = mkOption {
                type = types.str;
                default = "virtio";
                description = "The disk driver to use (e.g., 'virtio', 'scsi').";
              };
              size = mkOption {
                type = types.str;
                description = "The size of the disk (e.g., '10GiB', '100GiB').";
              };
            };
          }
        );
        default = [
          {
            driver = "virtio";
            size = "10GiB";
          }
          {
            driver = "virtio";
            size = "6GiB";
          }
        ];
        description = ''
          List of disks to create for the cluster nodes.
          Disks after the first one are added only to worker machines. (default = virtio:10GiB,virtio:6GiB)
        '';
      };
    };

    withKubespan = mkOption {
      type = types.bool;
      default = false;
      description = "Enable KubeSpan.";
    };

    checkKubectl = mkOption {
      type = types.bool;
      default = true;
      description = "Include kubectl connectivity in health checks.";
    };

    registryMirrors = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Registry mirrors to configure.
               Enable them via config.services.containers.*.registries.enable
               Define registries in config.services.containers.*.registries.providers.*
      '';
      example = [ "docker.io=http://localhost:5000" ];
    };

    configPatches = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Configuration patch files to apply.";
    };

    withDebug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug output.";
    };

    postStartHook = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Shell script to run after cluster starts.";
      example = ''
        kubectl apply -f ./manifests/
      '';
    };

    preStopHook = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Shell script to run before cluster stops.";
      example = ''
        kubectl get all --all-namespaces > cluster-state.log
      '';
    };
  };

  config = mkIf config.enable {
    outputs.settings.processes = {
      "${name}" = {
        command = startScript;
        environment = {
          KUBECONFIG = KUBECONFIG;
        };
        is_daemon = true;
        shutdown = {
          command = cleanupScript;
          timeout_seconds = 60;
        };
        ready_log_line = "Talos cluster '${config.clusterName}' started successfully";
      };
    };
  };
}

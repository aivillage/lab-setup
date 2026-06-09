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

  aivLabSettings = (import ./settings.nix { inherit pkgs; }).aiv-lab;
  cfg = config;

  KUBECONFIG = config.dataDir + "/kubeconfig";
  TALOSCONFIG = config.dataDir + "/talosconfig";
  patch_file = config.dataDir + "/dynamic-patch.yaml";

  talosHashes = {
    "v1.13.3" = {
      kernelSha256 = "sha256-w21KrDbQga+AFv+YdPKRFb8Uk9I+VWuZ01UxavoOmP8=";
      initramfsSha256 = "sha256-fCxTlvb1Gupt9QoPlI+mhA4vaYteC9fLJl3y0wGLP0k=";
    };
  };

  hashes =
    talosHashes.${config.talosVersion}
      or (throw "Unsupported Talos version: ${config.talosVersion}. Please add its hashes to the map in talos.nix.");

  talosKernel =
    if config.provisioner == "qemu" then
      pkgs.fetchurl {
        url = "https://github.com/siderolabs/talos/releases/download/${config.talosVersion}/vmlinuz-amd64";
        sha256 = hashes.kernelSha256;
      }
    else
      null;

  talosInitramfs =
    if config.provisioner == "qemu" then
      pkgs.fetchurl {
        url = "https://github.com/siderolabs/talos/releases/download/${config.talosVersion}/initramfs-amd64.xz";
        sha256 = hashes.initramfsSha256;
      }
    else
      null;

  allPatchFiles =
    config.configPatches
    ++ (lib.optional (config.dynamicPatch != null) "${config.dataDir}/dynamic-patch.yaml");

  startCommandArgs =
    let
      arg = lib.escapeShellArg;
      argStr = x: lib.escapeShellArg (toString x);

      baseArgs =
        lib.optionals config.qemu.useSudo [
          "sudo"
          "-E"
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
          primaryDisk = "virtio:${toString config.qemu.disk}MB";
          extraDisks = lib.genList (
            i: "${config.qemu.extra-disks-drivers}:${toString config.qemu.extra-disks-size}MB"
          ) config.qemu.extra-disks;
          allDisks = [ primaryDisk ] ++ extraDisks;
        in
        lib.optionals (config.provisioner == "qemu") (
          [
            "--presets"
            (arg config.qemu.presets)
            "--disks"
            (arg (lib.concatStringsSep "," allDisks))
            "--initrd-path"
            (arg talosInitramfs)
            "--vmlinuz-path"
            (arg talosKernel)
            # extra search paths for nixos ovmf images
            "extra-uefi-search-paths"
            "/run/libvirt/nix-ovmf"
          ]
          ++ lib.optionals (config.qemu.cidr != null) [
            "--cidr"
            (arg config.qemu.cidr)
          ]
          ++ lib.optionals (config.qemu.controlplanes != null) [
            "--controlplanes"
            (argStr config.qemu.controlplanes.count)
            "--cpus-controlplanes"
            (argStr config.qemu.controlplanes.cpus)
            "--memory-controlplanes"
            (argStr config.qemu.controlplanes.memory)
          ]
        );

    in
    baseArgs ++ dockerArgs ++ qemuArgs;

  # Setup script that prepares directories and configuration
  setupScript = pkgs.writeShellApplication {
    name = "setup-talos";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "Setting up Talos environment..."

      # Create required directories
      mkdir -p "${config.dataDir}"

      # Create dynamic patch file if content is provided
      ${lib.optionalString (config.dynamicPatch != null) ''
          echo "Creating dynamic patch file..."
          cat > "${patch_file}" << 'EOF'
          ${config.dynamicPatch}
        EOF
      ''}
      echo "Talos setup complete"
    '';
  };

  # Main start script for the Talos cluster
  startScript = pkgs.writeShellApplication {
    name = "start-talos";
    runtimeInputs = with pkgs; [
      config.package
      coreutils
    ];
    text = ''
      set -euo pipefail

      echo "Starting Talos cluster '${config.clusterName}'..."

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
    set +e  # Don't exit on error during cleanup

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

    provisioner = mkOption {
      type = types.enum [
        "docker"
        "qemu"
      ];
      default = "docker";
      description = "Provisioner to use for the cluster.";
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
        description = "Memory allocation in MB for worker nodes.";
      };
    };

    bootTimeout = mkOption {
      type = types.str;
      default = "2m";
      description = "Boot timeout for nodes.";
    };

    wait = mkOption {
      type = types.bool;
      default = true;
      description = "Wait for cluster to be ready.";
    };

    waitTimeout = mkOption {
      type = types.nullOr types.str;
      default = "20m";
      description = "Timeout to wait for cluster readiness.";
    };

    withDebug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug output.";
    };

    withKubespan = mkOption {
      type = types.bool;
      default = false;
      description = "Enable KubeSpan.";
    };

    registryMirrors = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Registry mirrors to configure.";
      example = [ "docker.io=http://localhost:5000" ];
    };

    configPatches = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Configuration patch files to apply.";
    };

    dynamicPatch = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Dynamic configuration patch content to apply. Will be written to a file at runtime.";
      example = ''
        machine:
          registries:
            config:
              ghcr.io:
                auth:
                  auth: "base64encodedcredentials"
          time:
            bootTimeout: 2m
      '';
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
      useSudo = mkOption {
        type = types.bool;
        default = false;
        description = "Use sudo for talosctl commands.";
      };
      presets = mkOption {
        type = types.listOf (
          types.enum [
            "iso"
            "pxe"
            "iso-secureboot"
          ]
        );
        default = [ "iso" ];
        description = ''
          talosctl cluster create qemu --help
            Available presets:
              - iso: Configure Talos to boot from an ISO from the Image Factory.
              - iso-secureboot: Configure Talos for Secureboot via ISO. Only available on Linux hosts.
              - pxe: Configure Talos to boot via PXE from the Image Factory.
            Note: exactly one of 'iso', 'iso-secureboot', 'pxe' or 'disk-image' presets must be specified.
        '';
      };
      controlplanes = {
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
          description = "Memory allocation in MB for worker nodes.";
        };
      };
      cidr = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "CIDR of the cluster network.";
      };
      disk = mkOption {
        type = types.int;
        default = 6144;
        description = "Disk size in MB for each node.";
      };
      extra-disks = mkOption {
        type = types.int;
        default = 0;
        description = "Disk size in MB for each node.";
      };
      extra-disks-size = mkOption {
        type = types.int;
        default = 5120;
        description = "Disk size in MB for each node.";
      };
      extra-disks-drivers = mkOption {
        type = types.enum [
          "virtio"
          "ide"
          "ahci"
          "scsi"
          "nvme"
          "megaraid"
        ];
        default = "nvme";
        description = "Disk size in MB for each node.";
      };
    };

    useLocalRegistries = mkOption {
      type = types.bool;
      default = true;
      description = "Set up local registry mirrors for QEMU provisioner.";
    };

    checkKubectl = mkOption {
      type = types.bool;
      default = true;
      description = "Include kubectl connectivity in health checks.";
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
      "${name}-setup" = {
        environment = {
          KUBECONFIG = KUBECONFIG;
        };
        command = setupScript;
        #is_one_shot = true;
      };

      "${name}" = {
        command = startScript;
        environment = {
          KUBECONFIG = KUBECONFIG;
        };

        depends_on."${name}-setup".condition = "process_completed_successfully";
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

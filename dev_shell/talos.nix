{
  pkgs,
  lib,
  config,
  name,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    mkPackageOption
    mkIf
    ;

  KUBECONFIG = config.dataDir + "/kubeconfig";
  TALOSCONFIG = config.dataDir + "/talosconfig";
  patch_file = config.dataDir + "/dynamic-patch.yaml";

  talosHashes = {
    "v1.11.0" = {
      kernelSha256 = "sha256-ymVDU/M58csSm6LVW3TGz/fERlzYxThsAfNzWqjJ6Qg=";
      initramfsSha256 = "sha256-S1DYzm00Lb8BlWr3/S5LK7E/XbUUPDDCgDhKcR8ocW8=";
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
    (lib.optionals config.useSudo [
      "sudo"
      "-E"
    ])
    ++ [
      (lib.getExe config.package)
      "cluster"
      "create"
      "--name"
      (lib.escapeShellArg config.clusterName)
      "--state"
      (lib.escapeShellArg config.dataDir)
      "--provisioner"
      (lib.escapeShellArg config.provisioner)
      "--talosconfig"
      (lib.escapeShellArg TALOSCONFIG)
      "--workers"
      (lib.escapeShellArg (toString config.workers))
      "--controlplanes"
      (lib.escapeShellArg (toString config.controlplanes))
      "--cpus"
      (lib.escapeShellArg config.cpus)
      "--cpus-workers"
      (lib.escapeShellArg config.cpusWorkers)
      "--memory"
      (lib.escapeShellArg (toString config.memory))
      "--memory-workers"
      (lib.escapeShellArg (toString config.memoryWorkers))
    ]
    ++ (lib.concatMap (patchFile: [
      "--config-patch"
      "@${(lib.escapeShellArg patchFile)}"
    ]) allPatchFiles)
    ++ (lib.optionals (config.cidr != null) [
      "--cidr"
      (lib.escapeShellArg config.cidr)
    ])
    ++ (lib.optional config.withDebug "--with-debug")
    ++ (lib.optional config.withKubespan "--with-kubespan")
    ++ (lib.optional config.withClusterDiscovery "--with-cluster-discovery")
    ++ (lib.concatMap (mirror: [
      "--registry-mirror"
      mirror
    ]) config.registryMirrors)
    # QEMU-specific options
    ++ (lib.optionals (config.provisioner == "qemu") (
      [
        "--extra-disks"
        (lib.escapeShellArg config.extra-disks)
        "--extra-disks-size"
        (lib.escapeShellArg config.extra-disks-size)
        "--extra-disks-drivers"
        (lib.escapeShellArg config.extra-disks-drivers)
        "--disk"
        (lib.escapeShellArg config.disk)
        "--initrd-path"
        (lib.escapeShellArg talosInitramfs)
        "--vmlinuz-path"
        (lib.escapeShellArg talosKernel)
      ]
      ++ (lib.optional config.withUefi "--with-uefi")
    ))
    # Docker-specific options
    ++ (lib.optionals (config.provisioner == "docker") (
      (lib.optional (config.image != null) [
        "--image"
        (lib.escapeShellArg config.image)
      ])
      ++ (lib.optional (config.exposedPorts != null) [
        "--exposed-ports"
        (lib.escapeShellArg config.exposedPorts)
      ])
    ));

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
      ${lib.optionalString config.useSudo ''
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
      CMD="${if config.useSudo then "sudo -E " else ""}${lib.getExe config.package} cluster destroy"
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

    talosVersion = mkOption {
      type = types.str;
      default = "v1.11.0";
      description = "Talos version to use.";
    };

    workers = mkOption {
      type = types.int;
      default = 1;
      description = "Number of worker nodes.";
    };

    controlplanes = mkOption {
      type = types.int;
      default = 1;
      description = "Number of control plane nodes.";
    };

    cpus = mkOption {
      type = types.str;
      default = 2.0;
      description = "CPU allocation for control plane nodes.";
    };

    cpusWorkers = mkOption {
      type = types.str;
      default = "2.0";
      description = "CPU allocation for worker nodes.";
    };

    memory = mkOption {
      type = types.int;
      default = 2048;
      description = "Memory allocation in MB for control plane nodes.";
    };

    memoryWorkers = mkOption {
      type = types.int;
      default = 2048;
      description = "Memory allocation in MB for worker nodes.";
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

    cidr = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "CIDR of the cluster network.";
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

    withClusterDiscovery = mkOption {
      type = types.bool;
      default = true;
      description = "Enable cluster discovery.";
    };

    withUefi = mkOption {
      type = types.bool;
      default = true;
      description = "Enable UEFI for QEMU provisioner.";
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

    image = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Docker image to use (docker provisioner only).";
    };

    exposedPorts = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Ports to expose (docker provisioner only).";
    };

    useLocalRegistries = mkOption {
      type = types.bool;
      default = true;
      description = "Set up local registry mirrors for QEMU provisioner.";
    };

    useSudo = mkOption {
      type = types.bool;
      default = false;
      description = "Use sudo for talosctl commands.";
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

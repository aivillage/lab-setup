# lab-setup/talos/default.nix
#
# Machine types, images, DHCP.
# Config generation (patches + per-machine) is in config.nix.
#
{
  inputs ? { },
  pkgs,
  lib ? (if inputs ? nixpkgs then inputs.nixpkgs.lib else pkgs.lib),
}:
let
  topInputs = inputs;
  inherit (lib) types mkOption;

  interfaceType = types.submodule {
    options = {
      ip = mkOption { type = types.str; default = ""; };
      mac = mkOption { type = types.str; };
      primary = mkOption { type = types.bool; default = false; };
      role = mkOption { type = types.str; default = "private"; };
    };
  };

  diskSelectorType = types.submodule {
    options = {
      size = mkOption {
        type = types.int;
        description = "Exact disk size in bytes used by Talos diskSelector";
      };
    };
  };

  machineModule = {
    options = {
      version = mkOption {
        type = types.str;
        default = "v1.13.3";
      };
      sha256 = mkOption { type = types.str; };
      schematicSha256 = mkOption { type = types.str; };
      name = mkOption {
        type = types.str;
        description = "Hostname of this machine";
      };
      controlPlane = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this is a control plane node";
      };
      wipe = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to wipe this specific machine on next PXE boot";
      };
      network-interfaces = mkOption {
        type = types.attrsOf interfaceType;
        description = "Network interfaces keyed by device name (e.g. enp1s0)";
      };
      bonding = mkOption {
        type = types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to aggregate private network interfaces into a bond0 device";
            };
            mode = mkOption {
              type = types.enum [ "active-backup" "802.3ad" "balance-tlb" "balance-alb" ];
              default = "802.3ad";
              description = "Linux bonding mode";
            };
            miimon = mkOption {
              type = types.nullOr types.int;
              default = 100;
              description = "MII link monitoring frequency in milliseconds";
            };
            updelay = mkOption {
              type = types.nullOr types.int;
              default = 200;
              description = "Delay before link is considered up in milliseconds";
            };
            downdelay = mkOption {
              type = types.nullOr types.int;
              default = 200;
              description = "Delay before link is considered down in milliseconds";
            };
          };
        };
        default = {
          enable = false;
          mode = "802.3ad";
          miimon = 100;
          updelay = 200;
          downdelay = 200;
        };
        description = "Link aggregation bonding configuration";
      };
      nvidia = mkOption {
        type = types.bool;
        default = false;
        description = "Whether this machine has NVIDIA GPUs";
      };
      tpm = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            present = mkOption {
              type = types.bool;
              default = true;
              description = "Whether hardware TPM 2.0 is present on the motherboard";
            };
            version = mkOption {
              type = types.nullOr types.str;
              default = "2.0";
              description = "TPM specification version";
            };
            device = mkOption {
              type = types.nullOr types.str;
              default = "/dev/tpmrm0";
              description = "TPM character device path";
            };
          };
        });
        default = null;
        description = "TPM 2.0 hardware specification";
      };
      disks = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            os = mkOption {
              type = types.nullOr (types.coercedTo types.str (dev: { device = dev; }) (types.submodule {
                options = {
                  device = mkOption {
                    type = types.str;
                    description = "Target OS disk device";
                  };
                  encrypted = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Enable LUKS2 system disk encryption";
                  };
                  provider = mkOption {
                    type = types.enum [ "tpm" "nodeId" ];
                    default = "tpm";
                    description = "LUKS2 key provider";
                  };
                };
              }));
              default = null;
              description = "Primary OS installation disk";
            };
            models = mkOption {
              type = types.nullOr (types.coercedTo types.str (dev: { device = dev; }) (types.submodule {
                options = {
                  device = mkOption {
                    type = types.str;
                    description = "Target disk device for local model storage";
                  };
                  mount = mkOption {
                    type = types.str;
                    default = "/var/models";
                    description = "Mount point for model storage volume";
                  };
                };
              }));
              default = null;
              description = "High-capacity model storage disk mounted on the node";
            };
          };
        });
        default = null;
        description = "Unified disk layout for OS and model storage";
      };
      diskSelector = mkOption {
        type = types.nullOr types.anything;
        default = null;
        description = "Talos diskSelector specification";
        example = {
          size = 512110190592;
        };
      };
      extraExtensions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional Talos system extensions beyond defaults";
      };
      extraPatches = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = "Additional Talos config patch files for this machine";
      };
      clusterName = mkOption {
        type = types.str;
        description = "Talos cluster name";
        default = "cluster";
      };
      clusterEndpoint = mkOption {
        type = types.str;
        description = "Talos cluster endpoint URL";
        default = "https://127.0.0.1:6443";
      };
      clusterVip = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Talos control plane virtual IP (VIP)";
      };
      coordinatorIp = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Coordinator IP address";
      };
      gateway = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Default gateway for private infrastructure cluster network";
      };
      clusterSubnet = mkOption {
        type = types.str;
        default = "0.0.0.0/0";
        description = "Private infrastructure cluster subnet";
      };
      upstreamDns = mkOption {
        type = types.listOf types.str;
        default = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        description = "Upstream DNS nameservers";
      };
      upstreamNtp = mkOption {
        type = types.listOf types.str;
        default = [
          "time.cloudflare.com"
        ];
        description = "Upstream NTP servers";
      };
      registryMirrors = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            remoteUrl = mkOption { type = types.str; };
            port = mkOption { type = types.port; };
          };
        });
        default = import ./registries.nix;
        description = "Container registry mirrors for node containerd configuration";
      };
    };
  };

  configLib = import ./config.nix { inherit pkgs lib inputs; };

  mkSchematic = (import ./schematic.nix { inherit pkgs lib; }).mkSchematic;

  mkImage =
    {
      machine,
      schematic,
    }:
    import ./image.nix { inherit pkgs; } {
      version = machine.version;
      sha256 = machine.sha256;
      schematic = schematic;

      platform = "metal";
      diskImage = "pxe-assets";
    };

  machine =
    machineAttrs:
    let
      eval = lib.evalModules {
        modules = [
          machineModule
          { config = machineAttrs; }
        ];
      };
      cfg = eval.config;

      schematic = mkSchematic {
        machine = cfg;
        sha256 = cfg.schematicSha256;
      };

      configScript = configLib.mkMachineConfig {
        machine = cfg;
        clusterName = cfg.clusterName;
        clusterEndpoint = cfg.clusterEndpoint;
        talosVersion = cfg.version;
        inherit schematic;
      };

      # Active interfaces on this machine (role is not "disabled" and ignore is false)
      activeIfaces = lib.filterAttrs (
        _dev: iface:
        (iface.role or "private") != "disabled" && !(iface.ignore or false)
      ) cfg.network-interfaces;

      nonPrivateIfaces = lib.filterAttrs (
        _dev: iface:
        (iface.role or "") != "private"
      ) activeIfaces;

      _assertControlPlaneSingleNic =
        if cfg.controlPlane then
          if !cfg.bonding.enable && (builtins.length (lib.attrNames activeIfaces)) > 1 then
            throw ''

              ╔══════════════════════════════════════════════════════════════════════════════════╗
              ║ [AI VILLAGE ARCHITECTURE VIOLATION] SINGLE NIC ENFORCEMENT                       ║
              ╚══════════════════════════════════════════════════════════════════════════════════╝
              Machine '${cfg.name}' is declared as a controlPlane node (controlPlane = true),
              but has multiple active network interfaces: ${builtins.concatStringsSep ", " (lib.attrNames activeIfaces)}.

              Control plane nodes must strictly use a SINGLE active network interface on the
              private infrastructure network (role = "private"). All secondary NICs must be disabled.

              To resolve:
              In machines.nix, set 'role = "disabled";' on all secondary interfaces for '${cfg.name}'.
            ''
          else if nonPrivateIfaces != { } then
            throw ''

              ╔══════════════════════════════════════════════════════════════════════════════════╗
              ║ [AI VILLAGE ARCHITECTURE VIOLATION] PRIVATE NETWORK ONLY                         ║
              ╚══════════════════════════════════════════════════════════════════════════════════╝
              Machine '${cfg.name}' is declared as a controlPlane node (controlPlane = true),
              but has non-private interface(s) enabled: ${builtins.concatStringsSep ", " (lib.attrNames nonPrivateIfaces)}.

              Control plane nodes must strictly reside ONLY on the private infrastructure network (role = "private").

              To resolve:
              In machines.nix, ensure the primary interface has 'role = "private";' and all others have 'role = "disabled";'.
            ''
          else
            true
        else
          true;
    in
    builtins.seq _assertControlPlaneSingleNic {
      name = cfg.name;
      machine = cfg;
      image = mkImage {
        machine = cfg;
        schematic = schematic;
      };

      dhcpHosts = lib.concatLists (
        lib.mapAttrsToList (_dev: iface:
          lib.optional ((iface.ip or "") != "" && (iface.role or "private") != "disabled")
            "${iface.mac},${iface.ip},${cfg.name}"
        ) cfg.network-interfaces
      );

      primaryIp = 
        let
          primaryIfaces = lib.filterAttrs (_: iface: iface.primary or false) cfg.network-interfaces;
          targetIface = if primaryIfaces != { } then builtins.head (lib.attrValues primaryIfaces) else builtins.head (lib.attrValues cfg.network-interfaces);
        in targetIface.ip;
      configScript = configScript;
    };

  machines =
    machineAttrsSet:
    let
      evaluatedMachines = lib.mapAttrs (
        name: attrs: machine (attrs // { inherit name; })
      ) machineAttrsSet;

      dhcpHosts = lib.concatLists (lib.mapAttrsToList (_name: m: m.dhcpHosts) evaluatedMachines);

      generateConfigs = pkgs.writeShellScriptBin "generate-configs" ''
        set -euo pipefail
        PATCHES_DIR="''${1:?Usage: generate-configs <patches-dir> [secrets-file]}"
        SECRETS_FILE="''${2:-}"

        ${lib.concatMapStringsSep "\n" (m: ''
          ${m.configScript}/bin/generate-config "$PATCHES_DIR" "$SECRETS_FILE"
        '') (lib.attrValues evaluatedMachines)}
      '';
    in
    {
      machines = evaluatedMachines;
      inherit dhcpHosts generateConfigs;
    };
  mkCluster =
    {
      lab,
      cluster,
      secrets ? { },
      inputs ? topInputs,
      ...
    }:
    let
      effectiveInputs = if inputs != { } then inputs else topInputs;
      labName = lab.name;
      coordinatorHostname = lab.coordinator.hostname or null;
      coordinatorIp = lab.coordinator.ip;
      controlVip = cluster.vip.ip;
      endpoint = cluster.vip.endpoint or "https://${controlVip}:6443";
      clusterSubnet = lab.subnets.private;
      publicSubnet = lab.subnets.public;
      clusterGateway = lab.gateway or null;
      upstreamDns = lab.dns or [ clusterGateway "1.1.1.1" ];
      upstreamNtp = lab.ntp or [ clusterGateway coordinatorIp "time.cloudflare.com" ];
      registryMirrors = lab.coordinator.registry.providers or (import ./registries.nix);

      talosCfg = cluster.talos or { };
      k8sCfg = cluster.k8s or { };
      resolvedWorkshops =
        let
          rawList = (k8sCfg.workshopHub or { }).workshops or [ ];
          available = effectiveInputs.workshops.workshops or { };
        in
        map (entry:
          let
            name = if builtins.isString entry then entry else entry.name;
            base = available.${name} or {
              name = name;
              description = name;
              user = {
                image = "ghcr.io/nbhdai/${name}:latest";
                port = 5000;
                env = { };
              };
            };
            merged = if builtins.isString entry then base else lib.recursiveUpdate base entry;
          in
          {
            name = merged.name;
            description = merged.description or merged.name;
            image = merged.user.image;
            port = merged.user.port or 5000;
            launchUri = merged.user.launch_uri or null;
            env = merged.user.env or { };
            service = merged.service or null;
            model = merged.model or null;
            extraIngressPorts = merged.user.extraIngressPorts or [ ];
          }
        ) rawList;
      version = talosCfg.version or "v1.13.3";
      machines = talosCfg.machines or { };
      compiledMachines = lib.mapAttrs (
        mName: mCfg:
        machine (
          {
            name = mName;
            clusterName = labName;
            clusterEndpoint = endpoint;
            clusterVip = controlVip;
            clusterSubnet = clusterSubnet;
            coordinatorIp = coordinatorIp;
            gateway = clusterGateway;
            upstreamDns = upstreamDns;
            upstreamNtp = upstreamNtp;
            registryMirrors = registryMirrors;
            version = version;
            sha256 =
              mCfg.sha256
              or (
                if (mCfg.nvidia or false) then
                  "sha256-otXfOROL6Z4JdT4FGuMUGB0i0jFBXudHneBeOFCl9U8="
                else
                  "sha256-G+f5ghwZAsY1nbXYcj4yawAIbOpBPAtfBI5ut+N6+6k="
              );
            schematicSha256 =
              mCfg.schematicSha256
              or (
                if (mCfg.nvidia or false) then
                  "sha256-0svhW3ksmvLqB8iNrFoIMw7QmkBGKqk3mlsXchZ+8aw="
                else
                  "sha256-IU2M1aPO1aKFMDPV2wct734+ZNgid7g0MUDlHgsN6wQ="
              );
            extraPatches = mCfg.extraPatches or [ ];
          }
          // mCfg
        )
      ) machines;

      generateConfigsScript = pkgs.writeShellScriptBin "generate-configs" ''
        set -euo pipefail
        PATCHES_DIR="''${1:?Usage: generate-configs <patches-dir> [secrets-file]}"
        SECRETS_FILE="''${2:-}"

        ${lib.concatMapStringsSep "\n" (m: ''
          ${m.configScript}/bin/generate-config "$PATCHES_DIR" "$SECRETS_FILE"
        '') (lib.attrValues compiledMachines)}
      '';

      patchArgs = { coordinatorIp = coordinatorIp; } 
        // (lib.optionalAttrs (talosCfg ? bootstrapCNI) { inherit (talosCfg) bootstrapCNI; })
        // (lib.optionalAttrs (k8sCfg ? manifestTargets) { k8sManifests = k8sCfg.manifestTargets; })
        // (lib.optionalAttrs (talosCfg ? patches) { talosPatches = talosCfg.patches; })
        // { overrides = (talosCfg.overrides or {}) // (k8sCfg.overrides or {}); }
        // {
          k8sWorkshopHub = if (k8sCfg ? workshopHub && k8sCfg.workshopHub != null) then (k8sCfg.workshopHub // { inherit resolvedWorkshops; }) else null;
          k8sVllm = k8sCfg.vllm or null;
          lab = lab;
          machines = compiledMachines;
        };

      clusterCli = import ../packages/cluster-cli {
        inherit pkgs;
        coordinator = coordinatorHostname;
        controlVip = controlVip;
        inherit endpoint;
        machines = compiledMachines;
      };

      nixosRebuildWrapper = pkgs.writeShellApplication {
        name = "nixos-rebuild";
        runtimeInputs = [
          pkgs.nixos-rebuild
          pkgs.coreutils
          pkgs.openssh
        ];
        runtimeEnv = {
          COORDINATOR_HOST = if coordinatorHostname != null then coordinatorHostname else "";
        };
        text = builtins.readFile ./scripts/nixos-rebuild.sh;
      };

      generatePatches = configLib.mkGeneratePatches patchArgs;

      devShell = pkgs.mkShell {
        name = labName;
        packages = [
          nixosRebuildWrapper
          clusterCli
          generateConfigsScript
          generatePatches
          pkgs.nix
          pkgs.python3
          pkgs.jq
          pkgs.curl
          pkgs.talosctl
          pkgs.kubectl
          pkgs.kubernetes-helm
          pkgs.k9s
          pkgs.cilium-cli
          pkgs.openssl
          pkgs.sops
          pkgs.age
          pkgs.age-plugin-se
          pkgs.age-plugin-yubikey
        ];

        shellHook = ''
          export PROJECT_ROOT="$PWD"
          export CLUSTER_DIR="$PROJECT_ROOT/.cluster"
          export TALOS_DIR="$CLUSTER_DIR/talos"
          export KUBECONFIG="$CLUSTER_DIR/k8s/kubeconfig"
          export TALOSCONFIG="$CLUSTER_DIR/talos/talosconfig"

          mkdir -p "$CLUSTER_DIR/talos" "$CLUSTER_DIR/k8s"

          if [ -t 1 ]; then
            echo -e "\033[1;36m${labName} shell\033[0m — cluster: \033[33m${labName}\033[0m"
            ${clusterCli}/bin/cluster --help
          fi
        '';
      };
    in
    {
      config = { inherit lab cluster secrets; };
      machines = compiledMachines;
      generateConfigs = generateConfigsScript;
      generatePatches = generatePatches;
      devShell = devShell;
    };
in
{
  inherit machine machines mkCluster;
  mkClusterDevShell = args: (mkCluster args).devShell;
  inherit (configLib) mkGeneratePatches;
}

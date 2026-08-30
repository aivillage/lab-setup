# lab-setup/talos/default.nix
#
# Machine types, images, DHCP.
# Config generation (patches + per-machine) is in config.nix.
#
{
  pkgs,
  lib,
  inputs,
}:
let
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
      osDisk = mkOption {
        type = types.nullOr (types.coercedTo types.str (dev: { device = dev; }) (types.submodule {
          options = {
            device = mkOption {
              type = types.str;
              description = "Explicit target disk device for Talos OS installation (e.g. /dev/disk/by-id/nvme-...)";
            };
            encrypted = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to enable LUKS2 system disk encryption";
            };
            provider = mkOption {
              type = types.enum [ "tpm" "nodeId" ];
              default = "tpm";
              description = "LUKS2 key provider: 'tpm' (TPM 2.0 hardware sealing + nodeID recovery; requires UEFI Secure Boot with signed UKI PCR measurements) or 'nodeId' (cluster PKI derivation only; recommended for netboot/PXE environments without Secure Boot)";
            };
          };
        }));
        default = null;
        description = "Target OS disk device and encryption configuration";
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
      coordinatorIp = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Coordinator IP address";
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
    in
    {
      name = cfg.name;
      machine = cfg;
      image = mkImage {
        machine = cfg;
        schematic = schematic;
      };

      dhcpHosts = lib.concatLists (
        lib.mapAttrsToList (_dev: iface: [
          "${iface.mac},${iface.ip},${cfg.name}"
        ]) cfg.network-interfaces
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
      ...
    }:
    let
      labName = lab.name;
      coordinatorHostname = lab.coordinator.hostname or null;
      coordinatorIp = lab.coordinator.ip;
      controlVip = cluster.vip.ip;
      endpoint = cluster.vip.endpoint or "https://${controlVip}:6443";
      clusterSubnet = lab.subnets.private;
      publicSubnet = lab.subnets.public;
      upstreamDns = lab.dns or [ coordinatorIp "1.1.1.1" ];
      upstreamNtp = lab.ntp or [ coordinatorIp "time.cloudflare.com" ];

      talosCfg = cluster.talos or { };
      k8sCfg = cluster.k8s or { };
      version = talosCfg.version or "v1.13.3";
      machines = talosCfg.machines or { };
      compiledMachines = lib.mapAttrs (
        mName: mCfg:
        machine (
          {
            name = mName;
            clusterName = labName;
            clusterEndpoint = endpoint;
            clusterSubnet = clusterSubnet;
            coordinatorIp = coordinatorIp;
            upstreamDns = upstreamDns;
            upstreamNtp = upstreamNtp;
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
            extraPatches = (mCfg.extraPatches or [ ]) ++ [
              (pkgs.writeText "network-patch.json" (builtins.toJSON (
                let
                  ifaces = mCfg.network-interfaces or { };
                  explicitPrivate = lib.filterAttrs (_name: iface: (iface.role or "") == "private" || (iface.primary or false)) ifaces;
                  primaryName = if explicitPrivate != { } then (lib.head (lib.attrNames explicitPrivate)) else (if ifaces != { } then (lib.head (lib.attrNames ifaces)) else "eth0");
                  nonPrimaryNames = lib.filter (name: name != primaryName) (lib.attrNames ifaces);

                  primaryConfig = {
                    interface = primaryName;
                    dhcp = true;
                  } // (if (mCfg.controlPlane or false) && controlVip != null then { vip = { ip = controlVip; }; } else { });

                  nonPrimaryConfigs = map (name: {
                    interface = name;
                    dhcp = false;
                  }) nonPrimaryNames;
                in {
                  machine = {
                    network = {
                      interfaces = [ primaryConfig ] ++ nonPrimaryConfigs;
                    };
                  };
                }
              )))
            ];
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
        // { overrides = (talosCfg.overrides or {}) // (k8sCfg.overrides or {}); };

      clusterCli = import ../packages/cluster-cli {
        inherit pkgs;
        coordinator = coordinatorHostname;
        controlVip = controlVip;
        inherit endpoint;
        machines = compiledMachines;
      };

      nixosRebuildWrapper = pkgs.writeShellScriptBin "nixos-rebuild" ''
        set -euo pipefail
        export TMPDIR="/tmp"
        export SSH_AUTH_SOCK="''${SSH_AUTH_SOCK:-$HOME/.ssh/ssh_auth_sock}"
        export NIX_SSHOPTS="''${NIX_SSHOPTS:--A}"

        FIRST_ARG="''${1:-}"

        case "$FIRST_ARG" in
          switch|boot|test|build|dry-run|build-vm|build-vm-with-bootloader|edit|repl)
            exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$@"
            ;;
          help|--help|-h|"")
            echo -e "\033[1;36mAI Village NixOS Rebuild Helper\033[0m"
            echo -e "Usage:"
            echo -e "  \033[1mnixos-rebuild <node-or-host> [action] [options...]\033[0m"
            echo -e "  \033[1mnixos-rebuild [action] [options...]\033[0m"
            echo -e "\nExamples:"
            echo -e "  nixos-rebuild spark2 switch      # Rebuild and switch spark2 over SSH"
            echo -e "  nixos-rebuild spark0 boot        # Rebuild and set boot profile on spark0"
            echo -e "  nixos-rebuild coordinator        # Rebuild and switch coordinator"
            echo -e "  nixos-rebuild switch --flake .#spark1\n"
            exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild --help
            ;;
        esac

        TARGET="$FIRST_ARG"
        shift

        if [ "$TARGET" = "coordinator" ]; then
          ${if coordinatorHostname != null then ''TARGET="${coordinatorHostname}"'' else ''
          echo -e "\033[1;31mError: No coordinator hostname defined in cluster.nix. Please specify target host explicitly (e.g. nixos-rebuild spark2 switch).\033[0m" >&2
          exit 1
          ''};
        fi

        ACTION="''${1:-switch}"
        case "$ACTION" in
          switch|boot|test|build|dry-run|build-vm|build-vm-with-bootloader)
            shift || true
            ;;
          *)
            ACTION="switch"
            ;;
        esac

        if [ "$(hostname 2>/dev/null)" = "$TARGET" ]; then
          echo -e "\033[1;36mRebuilding $TARGET ($ACTION) locally...\033[0m"
          exec sudo ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$ACTION" -L --flake "path:.#$TARGET" "$@"
        fi

        SSH_USER="admin"
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "admin@$TARGET" "true" 2>/dev/null; then
          SSH_USER="admin"
        elif ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "root@$TARGET" "true" 2>/dev/null; then
          SSH_USER="root"
        fi

        SUDO_FLAG=$([ "$SSH_USER" = "admin" ] && echo "--elevate=sudo" || echo "")
        echo -e "\033[1;36mRebuilding $TARGET ($ACTION) via $SSH_USER@$TARGET...\033[0m"
        exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$ACTION" -L --flake "path:.#$TARGET" --target-host "$SSH_USER@$TARGET" --build-host "$SSH_USER@$TARGET" $SUDO_FLAG "$@"
      '';

      devShell = pkgs.mkShell {
        name = labName;
        packages = [
          nixosRebuildWrapper
          clusterCli
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

          echo -e "\033[1;36m${labName} shell\033[0m — cluster: \033[33m${labName}\033[0m"
          ${clusterCli}/bin/cluster help
        '';
      };
    in
    {
      config = { inherit lab cluster secrets; };
      machines = compiledMachines;
      generateConfigs = generateConfigsScript;
      generatePatches = configLib.mkGeneratePatches patchArgs;
      devShell = devShell;
    };
in
{
  inherit machine machines mkCluster;
  mkClusterDevShell = args: (mkCluster args).devShell;
  inherit (configLib) mkGeneratePatches;
}

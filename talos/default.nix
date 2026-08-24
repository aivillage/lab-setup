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
      osDisk = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit target disk device for Talos OS installation (e.g. /dev/disk/by-id/nvme-...)";
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
    args@{
      name ? "lab1",
      network,
      talos,
      k8s ? { },
      ...
    }:
    let
      coordinatorHostname = network.coordinator.hostname;
      coordinatorIp = network.coordinator.ip;
      controlVip = network.vip.ip;
      endpoint = network.vip.endpoint;
      clusterSubnet = network.subnets.private;
      publicSubnet = network.subnets.public;
      upstreamDns = network.dns or [ coordinatorIp "1.1.1.1" ];
      upstreamNtp = network.ntp or [ coordinatorIp "time.cloudflare.com" ];
      version = talos.version;
      machines = talos.machines;
      compiledMachines = lib.mapAttrs (
        mName: mCfg:
        machine (
          {
            name = mName;
            clusterName = name;
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
        // (lib.optionalAttrs (talos ? bootstrapCNI) { inherit (talos) bootstrapCNI; })
        // (lib.optionalAttrs (k8s ? manifestTargets) { k8sManifests = k8s.manifestTargets; })
        // (lib.optionalAttrs (talos ? k8sModules) { k8sManifests = talos.k8sModules; })
        // (lib.optionalAttrs (talos ? patches) { talosPatches = talos.patches; })
        // (lib.optionalAttrs (talos ? modules) { talosPatches = talos.modules; })
        // (lib.optionalAttrs (talos ? extraPatches) { inherit (talos) extraPatches; })
        // { overrides = (talos.overrides or {}) // (k8s.overrides or {}); };

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
          TARGET="${coordinatorHostname}"
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
          exec sudo ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$ACTION" -L --flake ".#$TARGET" "$@"
        fi

        SSH_USER="admin"
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "admin@$TARGET" "true" 2>/dev/null; then
          SSH_USER="admin"
        elif ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no "root@$TARGET" "true" 2>/dev/null; then
          SSH_USER="root"
        fi

        SUDO_FLAG=$([ "$SSH_USER" = "admin" ] && echo "--elevate=sudo" || echo "")
        echo -e "\033[1;36mRebuilding $TARGET ($ACTION) via $SSH_USER@$TARGET...\033[0m"
        exec ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$ACTION" -L --flake ".#$TARGET" --target-host "$SSH_USER@$TARGET" --build-host "$SSH_USER@$TARGET" $SUDO_FLAG "$@"
      '';

      genSecrets = pkgs.writeShellScriptBin "cluster-gen-secrets" ''
        set -euo pipefail
        OUT_FILE="''${1:-secrets/talos.yaml}"
        
        if [ -f "$OUT_FILE" ]; then
          echo -e "\033[1;31m[ERROR] $OUT_FILE already exists!\033[0m"
          echo -e "\033[1;31mAborting to prevent catastrophic PKI loss.\033[0m"
          echo "If you are absolutely sure you want to destroy your cluster's PKI and generate a new one,"
          echo "use the --force-destroy-pki flag."
          if [ "''${2:-}" != "--force-destroy-pki" ] && [ "''${1:-}" != "--force-destroy-pki" ]; then
            exit 1
          fi
          
          # Automatic timestamped backup
          TS=$(date +%Y%m%d%H%M%S)
          BAK_FILE="$OUT_FILE.bak-$TS"
          echo "Creating timestamped backup of existing secrets at $BAK_FILE..."
          cp "$OUT_FILE" "$BAK_FILE"
        fi

        mkdir -p "$(dirname "$OUT_FILE")"
        RAW_TMP=$(mktemp)
        
        # Ensure cleanup
        trap 'rm -f "$RAW_TMP"' EXIT

        echo "Generating brand new cluster secrets..."
        ${pkgs.talosctl}/bin/talosctl gen secrets -o "$RAW_TMP"
        
        echo "Encrypting secrets via SOPS into $OUT_FILE..."
        ${pkgs.sops}/bin/sops --encrypt "$RAW_TMP" > "$OUT_FILE"
        
        echo -e "\033[1;32m[SUCCESS] Successfully generated and encrypted cluster secrets to $OUT_FILE!\033[0m"
      '';

      devShell = pkgs.mkShell {
        name = name;
        packages = [
          nixosRebuildWrapper
          clusterCli
          genSecrets
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

          echo -e "\033[1;36m${name} shell\033[0m — cluster: \033[33m${name}\033[0m"
          echo -e "  \033[1mcluster status\033[0m                     → inspect live registered nodes, K8s health & GPU status"
          echo -e "  \033[1mcluster wakeup <all|node>\033[0m          → wake up node(s) or entire cluster via Wake-on-LAN"
          echo -e "  \033[1mcluster shutdown <all|node>\033[0m        → shut down node(s) or entire cluster"
          echo -e "  \033[1mcluster wipe <status|req|cancel>\033[0m   → manage bare-metal node disk wipe lifecycle"
          echo -e "  \033[1mcluster show <machines|config|..>\033[0m  → inspect declared nodes, configs or reports"
          echo -e "  \033[1mcluster discover [-w]\033[0m              → fetch auto-generated discovery & write ./machines.nix"
          echo -e "  \033[1mcluster gen-secrets\033[0m                → safely bootstrap & encrypt brand new cluster PKI"
          echo -e "  \033[1mcluster gen <talos|k8s>\033[0m            → render Talos OS node configs or K8s manifests"
          echo -e "  \033[1mcluster apply <talos|k8s>\033[0m          → apply Talos node config or K8s manifests"
          echo -e "  \033[1mnixos-rebuild <host> [action]\033[0m      → rebuild & deploy any NixOS host in flake (e.g. spark2)"
        '';
      };
    in
    {
      config = args;
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

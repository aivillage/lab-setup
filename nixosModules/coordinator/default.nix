# =====================================================================
# lab-setup: Coordinator Top-Level Module
#
# Declares top-level coordinator options, core system packages, MOTD,
# system routing/sysctl, and imports modular coordinator subsystems.
# =====================================================================

{
  config,
  lib,
  pkgs,
  inputs ? null,
  inspector ? null,
  lab ? null,
  cluster ? null,
  secrets ? null,
  ...
}:

let
  cfg = config.lab.coordinator;
  labSafe = if lab != null then lab else { };
  clusterSafe = if cluster != null then cluster else { };
  secretsSafe = if secrets != null then secrets else { };

  # Determine default host IP from lab, networking interfaces, or fallback to null
  detectedIp =
    labSafe.coordinator.ip or (
      let
        addrs = lib.concatMap (i: map (a: a.address) i.ipv4.addresses) (lib.attrValues (config.networking.interfaces or { }));
      in
      if addrs != [ ] then lib.head addrs else null
    );

  # Determine default primary interface name with static IP or from lab
  detectedInterface =
    labSafe.coordinator.interface or (
      let
        ifaces = lib.filterAttrs (_name: iface: (iface.ipv4.addresses or [ ]) != [ ]) (config.networking.interfaces or { });
        names = lib.attrNames ifaces;
      in
      if names != [ ] then lib.head names else null
    );

  # Determine default gateway from lab or system networking
  detectedGateway =
    labSafe.gateway or (
      let gw = config.networking.defaultGateway or null; in
      if gw != null then (if lib.isAttrs gw then gw.address else gw) else null
    );
in
{
  imports = [
    ./service.nix
    ./netboot.nix
    ./registry.nix
    ./models.nix
  ];

  options.lab.coordinator = {
    enable = lib.mkEnableOption "Cluster coordinator server managing node discovery, netboot, wipe states, and Talos configs";

    ip = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "IP address of this PXE/DHCP/TFTP server";
      default = detectedIp;
    };

    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Network interface for dnsmasq to listen on";
      default = detectedInterface;
    };

    gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = detectedGateway;
      description = "Gateway IP address";
    };

    machines = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = clusterSafe.talos.machines or { };
      description = "Attribute set of Talos machine definitions";
    };

    talosSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = clusterSafe.secrets.sopsFile or secretsSafe.sopsFile or null;
      description = "Path to the encrypted talos.yaml SOPS file. It will be automatically decrypted and passed to the provisioner.";
    };

    privateSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = labSafe.subnets.private or null;
      description = "Private management subnet CIDR";
    };

    publicSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = labSafe.subnets.public or null;
      description = "Public ingress subnet CIDR";
    };

    generatePatches = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "The generated generate-patches script package from the cluster configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.ip != null && cfg.ip != "";
        message = "lab.coordinator: Could not auto-detect host IP. Please set `lab.coordinator.ip` explicitly.";
      }
      {
        assertion = cfg.gateway != null && cfg.gateway != "";
        message = "lab.coordinator: Could not auto-detect default gateway. Please configure `networking.defaultGateway` or set `lab.coordinator.gateway` explicitly.";
      }
      {
        assertion = cfg.interface != null && cfg.interface != "";
        message = "lab.coordinator: Could not auto-detect primary network interface. Please set `lab.coordinator.interface` explicitly.";
      }
      {
        assertion = cfg.privateSubnet != null && cfg.privateSubnet != "";
        message = "lab.coordinator: Private management subnet is missing. Please define `lab.subnets.private` in lab.nix.";
      }
      {
        assertion = cfg.publicSubnet != null && cfg.publicSubnet != "";
        message = "lab.coordinator: Public ingress subnet is missing. Please define `lab.subnets.public` in lab.nix.";
      }
    ];

    # Dynamically inject the SOPS definition if a file is provided
    sops.secrets = lib.mkIf (cfg.talosSopsFile != null) {
      "talos-secrets" = { sopsFile = cfg.talosSopsFile; };
    };

    networking.defaultGateway = lib.mkDefault cfg.gateway;
    networking.nameservers = lib.mkDefault [
      cfg.gateway
      "1.1.1.1"
      "8.8.8.8"
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
      "net.ipv4.conf.all.rp_filter" = 2;
      "net.ipv4.conf.default.rp_filter" = 2;
    } // (lib.optionalAttrs (cfg.interface != null) {
      "net.ipv4.conf.${cfg.interface}.rp_filter" = 2;
    });

    networking.firewall.trustedInterfaces = lib.filter (x: x != null) [
      cfg.interface
      "tailscale0"
    ];

    nixpkgs.config.allowUnsupportedSystem = true;

    environment.systemPackages = [
      pkgs.talosctl
      pkgs.kubectl
      pkgs.kubernetes-helm
      pkgs.k9s
      pkgs.cilium-cli
      (import ../../packages/cluster-cli { inherit pkgs; machines = cfg.machines; coordinator = "127.0.0.1"; })
    ];

    programs.zsh.interactiveShellInit = ''
      if [ -z "''${MOTD_SHOWN:-}" ]; then
        export MOTD_SHOWN=1
        TS_IP=$(ip -4 addr show dev tailscale0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "N/A")
        # AI Village Official Brand Palette:
        # Gold: \033[38;2;212;189;114m (#d4bd72)
        # Steel Blue: \033[38;2;103;177;215m (#67b1d7)
        # Sage Green: \033[38;2;137;196;162m (#89c4a2)
        # Muted Grey: \033[38;2;152;166;177m (#98a6b1)
        echo -e "\033[1;38;2;212;189;114mAIVILLAGE CLUSTER COORDINATOR (${config.networking.hostName})\033[0m"
        echo -e "   \033[38;2;137;196;162mNode IP:\033[0m      \033[38;2;103;177;215m${cfg.ip}\033[0m"
        echo -e "   \033[38;2;137;196;162mTailscale IP:\033[0m \033[38;2;103;177;215m$TS_IP\033[0m\n"
        echo -e "\033[1;38;2;212;189;114mCluster Management:\033[0m"
        echo -e "   Run \033[1;38;2;137;196;162mcluster --help\033[0m to view all available commands."
        echo -e "   Run \033[1;38;2;137;196;162mcluster status\033[0m for live cluster & node health."
        echo -e "   Run \033[1;38;2;137;196;162mjournalctl -u coordinator -f\033[0m for Coordinator daemon logs.\n"
      fi
    '';

    environment.variables = {
      CLUSTER_CONTROL_VIP = if cluster != null && cluster ? vip && cluster.vip ? ip then cluster.vip.ip else "";
    };
  };
}

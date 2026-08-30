# =====================================================================
# lab-setup: Pure Coordinator Module (nixosModules.coordinator)
#
# Configures dnsmasq (ProxyDHCP/DHCP + DNS + TFTP) and iPXE chainloading.
# Automatically routes PXE booting nodes based on MAC address:
#   - Known MAC address in `machines` -> Boots into Talos Linux.
#   - Unknown / uninspected MAC      -> Boots into Hardware Inspector Netboot.
#
# Build standalone netboot image:
#   nix build .#inspector-netboot
#
# Consumer does:
#   imports = [ inputs.lab-setup.nixosModules.pxe ];
#   lab-setup.pxe = {
#     enable = true;
#     proxyDhcp = true;  # Coexist with external DHCP
#     machines = machines;
#     wipe = false;
#   };
#
# Auto-detects IP address and domain name from host `config.networking`.
# =====================================================================

{
  config,
  lib,
  pkgs,
  inputs ? null,
  inspector ? null,
  lab ? null,
  cluster ? null,
  ...
}:

let
  cfg = config.lab.coordinator;

  # Determine default host IP from lab, networking interfaces, or fallback to null
  detectedIp =
    if lab != null && lab ? coordinator && lab.coordinator ? ip then
      lab.coordinator.ip
    else
      let
        addrs = lib.concatMap (i: map (a: a.address) i.ipv4.addresses) (lib.attrValues (config.networking.interfaces or { }));
      in
      if addrs != [ ] then lib.head addrs else null;

  # Determine default primary interface name with static IP or from lab
  detectedInterface =
    if lab != null && lab ? coordinator && lab.coordinator ? interface then
      lab.coordinator.interface
    else
      let
        ifaces = lib.filterAttrs (_name: iface: (iface.ipv4.addresses or [ ]) != [ ]) (config.networking.interfaces or { });
        names = lib.attrNames ifaces;
      in
      if names != [ ] then lib.head names else null;

  # Determine default gateway from lab or system networking
  detectedGateway =
    if lab != null && lab ? gateway then
      lab.gateway
    else
      let gw = config.networking.defaultGateway or null; in
      if gw != null then (if lib.isAttrs gw then gw.address else gw) else null;

  gatewayIp = cfg.gateway;

  rawMachines = if (lib.isAttrs cfg.machines && cfg.machines ? machines) then cfg.machines.machines else cfg.machines;
  machinesList =
    if lib.isAttrs rawMachines then
      lib.mapAttrsToList (name: m: (m.machine or m) // { inherit name; }) rawMachines
    else
      rawMachines;

  # Build dnsmasq address entries dynamically for each machine's network interfaces
  # Format: /<hostname>.<domain>/<ip> (e.g. /control.cluster.local/10.200.10.211)
  machineAddresses = lib.concatMap (
    m:
    let
      mCfg = m.machine or m;
      name = mCfg.name or m.name or "unknown";
      netIfaces = mCfg.network-interfaces or mCfg.networkInterfaces or { };
    in
    lib.concatMap (
      ifaceCfg:
      if ifaceCfg ? ip && ifaceCfg.ip != null then
        [ "/${name}.${cfg.domain}/${ifaceCfg.ip}" ]
      else
        [ ]
    ) (lib.attrValues netIfaces)
  ) machinesList;

  pxeBootFiles = import ./pxe-boot.nix {
    inherit pkgs inputs;
    ip = cfg.ip;
    machines = machinesList;
    inspector = inspector.config.system.build;
    generatePatches = cfg.generatePatches;
  };
in
{
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

    domain = lib.mkOption {
      type = lib.types.str;
      default =
        if lab != null && lab ? domain then
          lab.domain
        else if cluster != null && cluster ? lab && cluster.lab ? domain then
          cluster.lab.domain
        else if (config.networking.domain or null) != null then
          config.networking.domain
        else
          "cluster.local";
      description = "Domain name for dnsmasq";
    };

    gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = detectedGateway;
      description = "Gateway IP address";
    };

    proxyDhcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dnsmasq ProxyDHCP mode (coexist with external DHCP like Ubiquiti)";
    };

    machines = lib.mkOption {
      type = lib.types.either (lib.types.listOf lib.types.attrs) (lib.types.attrsOf lib.types.attrs);
      default =
        if cluster != null && cluster ? talos && cluster.talos ? machines then
          cluster.talos.machines
        else if cluster != null && cluster ? machines then
          cluster.machines
        else
          { };
      description = "List or attribute set of Talos machine definitions";
    };

    extraAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra static address entries for dnsmasq (e.g. /router.cluster.local/10.200.10.1)";
    };

    talosSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = if cluster != null && cluster ? secrets && cluster.secrets ? sopsFile then cluster.secrets.sopsFile else null;
      description = "Path to the encrypted talos.yaml SOPS file. It will be automatically decrypted and passed to the provisioner.";
    };

    privateSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if lab != null && lab ? subnets && lab.subnets ? private then lab.subnets.private else null;
      description = "Private management subnet CIDR";
    };

    publicSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if lab != null && lab ? subnets && lab.subnets ? public then lab.subnets.public else null;
      description = "Public ingress subnet CIDR";
    };

    dhcpRange = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "DHCP range for dnsmasq in non-proxy mode (e.g. '10.200.10.100,10.200.10.250,24h')";
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

    networking.domain = lib.mkDefault cfg.domain;
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
      (import ../packages/cluster-cli { inherit pkgs; machines = cfg.machines; coordinator = "127.0.0.1"; })
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
        echo -e "\033[1;38;2;212;189;114mCluster Commands:\033[0m"
        echo -e "   \033[1;38;2;137;196;162mcluster status\033[0m                          \033[38;2;152;166;177m→\033[0m Inspect live nodes, K8s & GPU health"
        echo -e "   \033[1;38;2;137;196;162mcluster wakeup <all|node>\033[0m               \033[38;2;152;166;177m→\033[0m Send Wake-on-LAN magic packet"
        echo -e "   \033[1;38;2;137;196;162mcluster shutdown <all|node>\033[0m             \033[38;2;152;166;177m→\033[0m Gracefully power off node(s)"
        echo -e "   \033[1;38;2;137;196;162mcluster wipe <status|req|cancel|logs>\033[0m   \033[38;2;152;166;177m→\033[0m Manage node disk wipe lifecycle"
        echo -e "   \033[1;38;2;137;196;162mcluster discover [-w]\033[0m                   \033[38;2;152;166;177m→\033[0m Fetch auto-generated discovery"
        echo -e "   \033[1;38;2;137;196;162mcluster show <machines|config|report>\033[0m   \033[38;2;152;166;177m→\033[0m Inspect declared nodes, configs or reports"
        echo -e "   \033[1;38;2;137;196;162mcluster gen-secrets\033[0m                     \033[38;2;152;166;177m→\033[0m Bootstrap & encrypt cluster PKI"
        echo -e "   \033[1;38;2;137;196;162mcluster gen <talos|k8s>\033[0m                 \033[38;2;152;166;177m→\033[0m Render Talos OS or K8s configs"
        echo -e "   \033[1;38;2;137;196;162mcluster apply <talos|k8s>\033[0m               \033[38;2;152;166;177m→\033[0m Apply Talos OS or K8s configs"
        echo -e "   \033[1;38;2;137;196;162mcluster help\033[0m                            \033[38;2;152;166;177m→\033[0m Display full command help menu"
        echo -e "   \033[1;38;2;137;196;162mjournalctl -u coordinator -f\033[0m            \033[38;2;152;166;177m→\033[0m Stream live Coordinator logs\n"
      fi
    '';

    environment.variables = {
      CLUSTER_CONTROL_VIP = if cluster != null && cluster ? vip && cluster.vip ? ip then cluster.vip.ip else "";
    };

    # Open firewall ports for TFTP, DNS, DHCP, and HTTP
    networking.firewall = {
      allowedUDPPorts = [
        53 # DNS
        67 # DHCP / ProxyDHCP
        69 # TFTP
      ];
      allowedTCPPorts = [
        53   # DNS
        80   # HTTP for PXE boot images
        8080 # Coordinator API & Talos config server
      ];
    };

    systemd.services.coordinator = {
      description = "AI Village Cluster Coordinator (Netboot, Discovery & Talos Configs)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PORT = "8080";
        PYTHONUNBUFFERED = "1";
        CONFIGS_DIR = "/var/lib/tftpboot/configs";
        GATEWAY_IP = gatewayIp;
        DNS_IP = detectedIp;
        PRIVATE_SUBNET = cfg.privateSubnet;
        PUBLIC_SUBNET = cfg.publicSubnet;
        FLAKE_MACHINES_FILE = "${pkgs.writeText "flake-machines.json" (builtins.toJSON (
          let
            raw = if lib.isAttrs cfg.machines then (cfg.machines.machines or cfg.machines) else { };
            filtered = lib.filterAttrs (k: _v: ! (lib.elem k [ "config" "devShell" "generateConfigs" "generatePatches" "machines" "wakeup" ])) raw;
          in
          lib.mapAttrs (name: m:
            let
              mCfg = m.machine or m;
              netIfaces = mCfg.network-interfaces or mCfg.networkInterfaces or { };
            in {
              name = mCfg.name or m.name or name;
              controlPlane = mCfg.controlPlane or (m.controlPlane or false);
              nvidia = mCfg.nvidia or (m.nvidia or false);
              macs = lib.filter (x: x != null) (
                lib.mapAttrsToList (_iface: attrs: attrs.mac or null) netIfaces
              );
              iface =
                let
                  ifaces = lib.mapAttrsToList (k: _v: k) netIfaces;
                in
                if ifaces != [ ] then lib.head ifaces else "eth0";
              pxe_ip = mCfg.ip or (m.ip or null);
            }) filtered
        ))}";
      } // (lib.optionalAttrs (cfg.talosSopsFile != null) {
        SECRETS_FILE = config.sops.secrets."talos-secrets".path;
      });

      restartTriggers = [
        (builtins.readFile ../packages/coordinator/server.py)
      ];

      serviceConfig = {
        ExecStart = "${lib.getExe (pkgs.writers.writePython3Bin "coordinator" { doCheck = false; } (builtins.readFile ../packages/coordinator/server.py))}";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = [
          "coordinator"
        ];
        StateDirectoryMode = "0755";
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts."coordinator-netboot-server" = {
        default = true;
        root = "/var/lib/tftpboot";
        locations."/" = {
          extraConfig = ''
            autoindex on;
            sendfile off;
            tcp_nopush off;
            tcp_nodelay on;
            keepalive_timeout 65s;
          '';
        };
      };
    };

    # Set up TFTP directory and iPXE boot files using the auto-tmpfiles generator
    systemd.tmpfiles.rules = pxeBootFiles;

    # Configure dnsmasq for DNS, TFTP, and PXE booting
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        # Disable DNS server if proxyDhcp is active to avoid port 53 conflicts / DNS hijacking
        port = if cfg.proxyDhcp then 0 else 53;

        # General settings
        interface = cfg.interface;
        bind-interfaces = true;
        domain = cfg.domain;
        log-dhcp = true;

        # Disable DNS caching if desired, or set a reasonable size
        cache-size = 1000;

        # Upstream DNS servers
        server = [
          "1.1.1.1"
          "8.8.8.8"
        ];

        # DHCP & PXE settings
        dhcp-range =
          if cfg.proxyDhcp then
            [ "${cfg.ip},proxy" ]
          else if cfg.dhcpRange != null then
            [ cfg.dhcpRange ]
          else
            [ ];

        # Router and DNS options passed to DHCP clients (only in non-proxy mode)
        dhcp-option =
          if cfg.proxyDhcp then
            [ ]
          else
            [
              "option:router,${gatewayIp}"
              "option:dns-server,${cfg.ip}"
            ];

        # Static DNS entries generated from machines attrset
        address = [
          "/${config.networking.hostName}.${cfg.domain}/${cfg.ip}"
        ] ++ machineAddresses ++ cfg.extraAddresses;

        # Enable TFTP server
        enable-tftp = true;
        tftp-root = "/var/lib/tftpboot";

        # Match iPXE user class (Option 77 & Option 175) to prevent boot loops
        dhcp-userclass = "set:ipxe,iPXE";
        dhcp-match = [
          "set:ipxe,175"
          "set:7,60,PXEClient:Arch:00007"
          "set:9,60,PXEClient:Arch:00009"
          "set:7,option:client-arch,7"
          "set:9,option:client-arch,9"
        ];

        # Legacy BIOS vs UEFI boot filename selection
        dhcp-boot = [
          # If client is already running iPXE, serve the iPXE boot script
          "tag:ipxe,boot.ipxe"
          # UEFI x86-64 -> serve ipxe.efi ONLY if NOT already running iPXE!
          "tag:!ipxe,tag:7,ipxe.efi"
          # UEFI BC -> serve ipxe.efi ONLY if NOT already running iPXE!
          "tag:!ipxe,tag:9,ipxe.efi"
          # Default UEFI bootloader -> serve ipxe.efi ONLY if NOT already running iPXE!
          "tag:!ipxe,ipxe.efi"
        ];

        # ProxyDHCP PXE Service broadcast entries
        dhcp-option-force = [
          "tag:ipxe,option:bootfile-name,boot.ipxe"
        ];
        pxe-prompt = "Booting PXE..., 1";
        pxe-service = [
          "x86-64_EFI, Boot iPXE UEFI, ipxe.efi"
          "X86-64_EFI, Boot iPXE UEFI, ipxe.efi"
        ];
      };
    };
  };
}

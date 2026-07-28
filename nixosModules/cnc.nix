# =====================================================================
# lab-setup: Pure PXE Boot & CNC Module (nixosModules.pxe / cnc.nix)
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
  inspector,
  ...
}:

let
  cfg = config.lab-setup.pxe;

  # Determine default host IP from networking interfaces or fallback to 10.211.0.10
  detectedIp =
    let
      addrs = lib.concatMap (i: map (a: a.address) i.ipv4.addresses) (lib.attrValues (config.networking.interfaces or { }));
    in
    if addrs != [ ] then lib.head addrs else "10.211.0.10";

  # Determine default primary interface name from networking interfaces
  detectedInterface =
    let
      ifaces = lib.attrNames (config.networking.interfaces or { });
    in
    if ifaces != [ ] then lib.head ifaces else "enp1s0";

  # Extract gateway IP cleanly handling string or attrset (e.g. { address = "10.211.0.1"; })
  gatewayIp =
    let
      gw = config.networking.defaultGateway;
    in
    if gw != null then (if lib.isAttrs gw then gw.address else gw) else cfg.gateway;

  machinesList = if lib.isAttrs cfg.machines then lib.attrValues cfg.machines else cfg.machines;

  # Build dnsmasq address entries dynamically for each machine's network interfaces
  # Format: /<hostname>.<domain>/<ip> (e.g. /control.cluster.local/10.211.0.1)
  machineAddresses = lib.concatMap (
    m:
    lib.mapAttrsToList (_ifaceName: ifaceCfg: "/${m.name}.${cfg.domain}/${ifaceCfg.ip}") (
      m.network-interfaces or m.networkInterfaces or { }
    )
  ) machinesList;

  pxeBootFiles = import ./pxe-boot.nix {
    inherit pkgs;
    ip = cfg.ip;
    machines = machinesList;
    inspector = inspector.config.system.build;
    wipe = cfg.wipe;
  };
in
{
  options.lab-setup.pxe = {
    enable = lib.mkEnableOption "PXE boot server for Talos machines";

    ip = lib.mkOption {
      type = lib.types.str;
      description = "IP address of this PXE/DHCP/TFTP server";
      default = detectedIp;
    };

    interface = lib.mkOption {
      type = lib.types.str;
      description = "Network interface for dnsmasq to listen on";
      default = detectedInterface;
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = if (config.networking.domain or null) != null then config.networking.domain else "cluster.local";
      description = "Domain name for dnsmasq";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "10.211.0.1";
      description = "Gateway IP address";
    };

    proxyDhcp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable dnsmasq ProxyDHCP mode (coexist with external DHCP like Ubiquiti)";
    };

    wipe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Wipe disk before installing Talos";
    };

    machines = lib.mkOption {
      type = lib.types.either (lib.types.listOf lib.types.attrs) (lib.types.attrsOf lib.types.attrs);
      default = { };
      description = "List or attribute set of Talos machine definitions";
    };

    extraAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra static address entries for dnsmasq (e.g. /router.cluster.local/10.211.0.1)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Open firewall ports for TFTP, DNS, and DHCP
    networking.firewall = {
      allowedUDPPorts = [
        53 # DNS
        67 # DHCP / ProxyDHCP
        69 # TFTP
      ];
      allowedTCPPorts = [
        53 # DNS
      ];
    };

    # Set up TFTP directory and iPXE boot files using the auto-tmpfiles generator
    systemd.tmpfiles.rules = pxeBootFiles;

    # Configure dnsmasq for DNS, TFTP, and PXE booting
    services.dnsmasq = {
      enable = true;
      settings = {
        # General settings
        interface = cfg.interface;
        bind-interfaces = true;
        domain = cfg.domain;

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
            [ "${gatewayIp},proxy" ]
          else
            [ "10.211.0.100,10.211.0.250,24h" ];

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

        # PXE boot options
        # Match iPXE user class to prevent boot loops
        dhcp-userclass = "set:ipxe,iPXE";

        # Legacy BIOS vs UEFI boot filename selection
        # Tag 00007 = EFI x86-64, Tag 00011 = EFI ARM64, Tag 00000 = Legacy BIOS
        dhcp-boot = [
          # If client is already running iPXE, serve the iPXE boot script
          "tag:ipxe,boot.ipxe"
          # UEFI x86-64 -> serve ipxe.efi
          "tag:7,ipxe.efi"
          # UEFI BC -> serve ipxe.efi
          "tag:9,ipxe.efi"
          # Default legacy BIOS -> serve undionly.kpxe
          "undionly.kpxe"
        ];
      };
    };
  };
}

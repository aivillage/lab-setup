# =====================================================================
# lab-setup: Coordinator Netboot Module
#
# Configures dnsmasq (ProxyDHCP + TFTP), nginx (HTTP boot server),
# firewall ports (67, 69, 80), and iPXE boot tmpfiles rules.
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

  rawMachines = cfg.machines;
  compiledCluster =
    if lib.isAttrs rawMachines && rawMachines != { } then
      let
        firstVal = lib.head (lib.attrValues rawMachines);
        isCompiled = (lib.isAttrs firstVal && firstVal ? configScript);
      in
      if isCompiled then
        { machines = rawMachines; generatePatches = cfg.generatePatches; }
      else
        (import ../../talos { inherit pkgs lib inputs; }).mkCluster {
          inherit lab inputs;
          cluster = if cluster != null then cluster else { talos = { machines = rawMachines; }; };
        }
    else
      { machines = { }; generatePatches = cfg.generatePatches; };

  compiledMachines = if compiledCluster ? machines then compiledCluster.machines else rawMachines;
  machinesList = if lib.isAttrs compiledMachines then lib.attrValues compiledMachines else [ ];

  pxeBootFiles = import ./pxe-boot.nix {
    inherit pkgs inputs;
    ip = cfg.ip;
    machines = machinesList;
    inspector = inspector.config.system.build;
    generatePatches = if cfg.generatePatches != null then cfg.generatePatches else (compiledCluster.generatePatches or null);
  };
in
{
  config = lib.mkIf cfg.enable {
    # Open firewall ports for TFTP, DNS, DHCP, and HTTP
    networking.firewall = {
      allowedUDPPorts = [
        67 # DHCP / ProxyDHCP
        69 # TFTP
      ];
      allowedTCPPorts = [
        80 # HTTP for PXE boot images
      ];
    };

    # Set up TFTP directory and iPXE boot files using the auto-tmpfiles generator
    systemd.tmpfiles.rules = pxeBootFiles;

    services = {
      nginx = {
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

      # Configure dnsmasq for DNS, TFTP, and PXE booting
      dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          # Disable DNS server (ProxyDHCP and TFTP netboot only)
          port = 0;

          # General settings
          interface = cfg.interface;
          bind-interfaces = true;
          log-dhcp = true;

          # DHCP & PXE settings
          dhcp-range = [ "${cfg.ip},proxy" ];

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
  };
}

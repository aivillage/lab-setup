# =====================================================================
# lab-setup/pxe/default.nix
#
# Pure PXE boot module. Configures dnsmasq (DHCP + DNS + TFTP) and
# iPXE chainloading to boot each machine into either its Talos image
# or the inspector netboot image, routed by MAC address.
#
# Consumer does:
#   imports = [ inputs.lab-setup.nixosModules.pxe ];
#   lab-setup.pxe = {
#     enable = true;
#     ip = "10.211.0.10";
#     machines = [ { ... } ];
#     inspectorImage = <netboot build>;
#   };
#
# Everything else (ZFS, users, SSH, tailscale, packages) belongs in
# the lab repo's own configuration.nix.
# =====================================================================
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (lib)
    types
    mkOption
    mkEnableOption
    mkIf
    concatMap
    ;

  cfg = config.lab-setup.pxe;

  inspector = lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { inherit inputs; };
    modules = [
      (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
      ./inspector.nix
    ];
  };
  machineType = types.submodule (import ../machine.nix { inherit lib; });
in
{
  options.lab-setup.pxe = {
    enable = mkEnableOption "PXE boot server for Talos machines";

    ip = mkOption {
      type = types.str;
      description = "IP address of this PXE/DHCP/TFTP server";
      default = "10.211.0.10";
    };

    mount-point = mkOption {
      type = types.path;
      description = "NFS mount point";
    };

    machines = mkOption {
      type = types.listOf machineType;

      description = "Talos machines to PXE boot, each with image and boot mode";
    };

    # DHCP

    interface = mkOption {
      type = types.str;
      default = "enp1s0";
      description = "Network interface dnsmasq listens on";
    };

    dhcpRange = mkOption {
      type = types.str;
      default = "10.211.0.100,10.211.0.200,255.255.255.0,24h";
    };

    extraDhcpHosts = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional static dhcp-host entries beyond the machine inventory";
    };

    extraAddresses = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra dnsmasq address= entries";
    };
  };

  # ════════════════════════════════════════════════════════════════
  # Implementation
  # ════════════════════════════════════════════════════════════════
  config = mkIf cfg.enable {

    services.nfs.server = {
      enable = true;
      exports = ''
        ${cfg.mount-point} 10.211.0.0/24(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
      '';
    };

    # ── dnsmasq: DHCP + DNS + TFTP + PXE ────────────────────────
    services.resolved.enable = false;

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;
      settings = {
        interface = [ cfg.interface ];
        bind-interfaces = true;
        log-dhcp = true;

        # DNS
        domain-needed = true;
        bogus-priv = true;
        server = cfg.nameservers;
        expand-hosts = true;
        domain = cfg.domain;

        # DHCP
        dhcp-range = [ cfg.dhcpRange ];
        dhcp-option = [
          "option:router,${cfg.gateway}"
          "option:dns-server,${cfg.ip}"
        ];

        # Static hosts — derived from machine inventory
        dhcp-host = (concatMap cfg.machines) ++ cfg.extraDhcpHosts;
        address = [ "/nas/${cfg.ip}" ] ++ cfg.extraAddresses;

        # TFTP / PXE chainloading
        enable-tftp = true;
        tftp-root = "/var/lib/tftpboot";

        dhcp-match = [
          "set:efi-x86_64,option:client-arch,7"
          "set:efi-x86_64,option:client-arch,9"
          "set:ipxe,175"
        ];

        dhcp-boot = [
          "tag:!ipxe,tag:!efi-x86_64,undionly.kpxe"
          "tag:!ipxe,tag:efi-x86_64,ipxe.efi"
          "tag:ipxe,boot.ipxe"
        ];
      };
    };

    # ── Firewall: open DHCP + DNS + TFTP ────────────────────────
    networking.firewall = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [
        53
        67
        69
      ];
    };

    # ── TFTP directory tree ─────────────────────────────────────
    systemd.tmpfiles.rules =
      import ./pxe-boot.nix {
        inherit pkgs;
        ip = cfg.ip;
        machines = cfg.machines;
        inspector = inspector;
      }
      ++ [
        "z ${cfg.mount-point} 0777 nobody nogroup -"
      ];
  };
}

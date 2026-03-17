# =====================================================================
# lab-setup/nixos/default.nix
#
# Single entry point. Consumer does:
#   imports = [ inputs.lab-setup.nixosModules.default ];
#   lab-setup.nas = { ip = "..."; control = { ... }; workers = [ ... ]; };
#
# Everything else is derived.
# =====================================================================
{ config, lib, pkgs, ... }:
let
  inherit (lib) types mkOption mkEnableOption mkIf concatMap optional optionalAttrs;
  cfg = config.lab-setup.nas;

  # ── Type definitions matching the exact inventory shape ────────
  nodeType = types.submodule {
    options = {
      host     = mkOption { type = types.str; };
      ip1      = mkOption { type = types.str; };
      ip2      = mkOption { type = types.str; };
      mac1     = mkOption { type = types.str; };
      mac2     = mkOption { type = types.str; };
      slowIp1  = mkOption { type = types.str; };
      slowIp2  = mkOption { type = types.str; };
      slowMac1 = mkOption { type = types.str; };
      slowMac2 = mkOption { type = types.str; };
    };
  };

  # ── Derive dnsmasq dhcp-host lines from a node ────────────────
  mkDhcpHosts = node: [
    "${node.mac1},${node.ip1},${node.host}"
    "${node.mac2},${node.ip2},${node.host}"
    "${node.slowMac1},${node.slowIp1},${node.host}"
    "${node.slowMac2},${node.slowIp2},${node.host}"
  ];

  allNodes = [ cfg.control ] ++ cfg.workers;

  # ── PXE boot script ──────────────────────────────────────────
  bootScript = pkgs.writeText "boot.ipxe" ''
    #!ipxe
    dhcp
    echo ${cfg.pxe.bootMessage}
    kernel tftp://${cfg.ip}/kernel ${cfg.pxe.kernelCmdline}
    initrd tftp://${cfg.ip}/initrd
    boot
  '';

in
{
  options.lab-setup.nas = {
    enable = mkEnableOption "lab-setup NAS / cluster control node";

    # ── The inventory — this is all the consumer provides ───────
    ip = mkOption {
      type = types.str;
      description = "Static IP of the NAS/control node";
    };

    control = mkOption {
      type = nodeType;
      description = "Control plane node inventory";
    };

    workers = mkOption {
      type = types.listOf nodeType;
      default = [];
      description = "Worker node inventory";
    };

    # ── Tunables with sane defaults ─────────────────────────────
    hostId = mkOption {
      type = types.str;
      description = "8-char hex host ID (required for ZFS)";
    };

    hostname = mkOption {
      type = types.str;
      default = "cluster-control";
    };

    interface = mkOption {
      type = types.str;
      default = "enp1s0";
    };

    gateway = mkOption {
      type = types.str;
      default = "10.211.0.1";
    };

    nameservers = mkOption {
      type = types.listOf types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
    };

    domain = mkOption {
      type = types.str;
      default = "cluster.local";
    };

    dhcpRange = mkOption {
      type = types.str;
      default = "10.211.0.100,10.211.0.200,255.255.255.0,24h";
    };

    subnet = mkOption {
      type = types.str;
      default = "10.211.0.0/24";
      description = "Subnet for NFS exports";
    };

    adminSshKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "SSH public keys for the admin user";
    };

    extraAddresses = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra dnsmasq address= entries";
    };

    # ── ZFS / NFS ───────────────────────────────────────────────
    zfs = {
      dataset = mkOption {
        type = types.str;
        default = "tank/share";
      };
      mountPoint = mkOption {
        type = types.str;
        default = "/mnt/data";
      };
    };

    # ── Tailscale ───────────────────────────────────────────────
    tailscale = {
      enable = mkEnableOption "Tailscale VPN";
      authKeyFile = mkOption {
        type = types.str;
        default = "/var/keys/tailscale_key";
      };
    };

    # ── PXE / Talos boot ───────────────────────────────────────
    pxe = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };

      talosImages = mkOption {
        type = types.nullOr types.package;
        default = null;
        description = "Derivation with vmlinuz and initrd. Build via lab-setup.lib.mkTalosImage.";
      };

      bootMessage = mkOption {
        type = types.str;
        default = "Starting Talos Boot...";
      };

      kernelCmdline = mkOption {
        type = types.str;
        default = "talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1";
      };

      # Override for inspector or other netboot targets
      overrideKernel = mkOption { type = types.nullOr types.str; default = null; };
      overrideInitrd = mkOption { type = types.nullOr types.str; default = null; };
      overrideCmdline = mkOption { type = types.nullOr types.str; default = null; };
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
    };
  };

  # ══════════════════════════════════════════════════════════════
  # Implementation — everything below is derived from the above
  # ══════════════════════════════════════════════════════════════
  config = mkIf cfg.enable {

    # ── 1. Boot & System Basics ─────────────────────────────────
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    networking.hostName = cfg.hostname;
    networking.hostId = cfg.hostId;

    # ── 2. ZFS & NFS ───────────────────────────────────────────
    boot.supportedFilesystems = [ "zfs" ];
    services.zfs.autoScrub.enable = true;

    fileSystems.${cfg.zfs.mountPoint} = {
      device = cfg.zfs.dataset;
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

    services.nfs.server = {
      enable = true;
      exports = ''
        ${cfg.zfs.mountPoint} ${cfg.subnet}(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
      '';
    };

    # ── 3. Networking & Firewall ────────────────────────────────
    networking.interfaces.${cfg.interface}.ipv4.addresses = [{
      address = cfg.ip;
      prefixLength = 24;
    }];
    networking.defaultGateway = cfg.gateway;
    networking.nameservers = cfg.nameservers;

    services.tailscale = mkIf cfg.tailscale.enable {
      enable = true;
      authKeyFile = cfg.tailscale.authKeyFile;
      extraUpFlags = [ "--ssh" ];
    };

    networking.firewall = {
      enable = true;
      trustedInterfaces = optional cfg.tailscale.enable "tailscale0";
      allowedTCPPorts = [ 22 53 2049 ];
      allowedUDPPorts = [ 53 67 69 ];
    };

    # ── 4. SSH ──────────────────────────────────────────────────
    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # ── 5. User ─────────────────────────────────────────────────
    security.sudo.wheelNeedsPassword = false;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.adminSshKeys;
    };

    # ── 6. Packages ─────────────────────────────────────────────
    environment.systemPackages = (with pkgs; [
      vim wget nano git htop zsh
      talosctl kubectl k9s cilium-cli hubble
      zfs nmap tcpdump
    ]) ++ cfg.extraPackages;

    # ── 7. DHCP / DNS / PXE (dnsmasq) ──────────────────────────
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

        # Static hosts — derived from inventory
        dhcp-host = concatMap mkDhcpHosts allNodes;
        address = [ "/nas/${cfg.ip}" ] ++ cfg.extraAddresses;
      } // optionalAttrs cfg.pxe.enable {
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

    # ── 8. PXE / TFTP files ────────────────────────────────────
    systemd.tmpfiles.rules = (lib.optionals cfg.pxe.enable (
      let
        kernelPath = if cfg.pxe.overrideKernel != null
                     then cfg.pxe.overrideKernel
                     else "${cfg.pxe.talosImages}/vmlinuz";
        initrdPath = if cfg.pxe.overrideInitrd != null
                     then cfg.pxe.overrideInitrd
                     else "${cfg.pxe.talosImages}/initrd";
        actualBootScript = if cfg.pxe.overrideCmdline != null
          then pkgs.writeText "boot.ipxe" ''
            #!ipxe
            dhcp
            echo ${cfg.pxe.bootMessage}
            kernel tftp://${cfg.ip}/kernel ${cfg.pxe.overrideCmdline}
            initrd tftp://${cfg.ip}/initrd
            boot
          ''
          else bootScript;
      in [
        "d /var/lib/tftpboot 0755 root root -"
        "L+ /var/lib/tftpboot/ipxe.efi - - - - ${pkgs.ipxe}/ipxe.efi"
        "L+ /var/lib/tftpboot/undionly.kpxe - - - - ${pkgs.ipxe}/undionly.kpxe"
        "L+ /var/lib/tftpboot/kernel - - - - ${kernelPath}"
        "L+ /var/lib/tftpboot/initrd - - - - ${initrdPath}"
        "L+ /var/lib/tftpboot/boot.ipxe - - - - ${actualBootScript}"
      ]
    )) ++ [
      "z ${cfg.zfs.mountPoint} 0777 nobody nogroup -"
    ];

    system.stateVersion = "25.11";
  };
}
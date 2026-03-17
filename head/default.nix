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
{ config, lib, pkgs, ... }:
let
  inherit (lib) types mkOption mkEnableOption mkIf
                concatMap concatMapStringsSep mapAttrsToList
                concatLists toLower optionalAttrs;

  cfg = config.lab-setup.pxe;

  # ── Machine type for the PXE module ───────────────────────────
  # Each entry pairs a talos/machine.nix machine definition with
  # its built image and a boot mode selector.
  pxeMachineType = types.submodule {
    options = {
      machine = mkOption {
        type = import ../talos/machine.nix { inherit lib; };
        description = "Machine definition (from talos/machine.nix)";
      };

      image = mkOption {
        type = types.package;
        description = "PXE assets derivation (contains vmlinuz + initrd)";
      };

      mode = mkOption {
        type = types.enum [ "talos" "inspector" ];
        default = "talos";
        description = ''
          Boot mode for this machine.
          - "talos": boot the machine-specific Talos kernel/initrd
          - "inspector": boot the shared inspector netboot image
        '';
      };
    };
  };

  # ── Collect all MACs from a machine ───────────────────────────
  allMacsFor = m:
    concatLists (mapAttrsToList (_dev: iface: [ iface.mac ]) m.machine.network-interfaces);

  # ── DHCP static host entries ──────────────────────────────────
  mkDhcpHosts = entry:
    concatLists (mapAttrsToList (_dev: iface: [
      "${iface.mac},${iface.ip},${entry.machine.name}"
    ]) entry.machine.network-interfaces);

  # ── iPXE boot script ──────────────────────────────────────────
  #
  # Flow:
  #   1. DHCP → chainload iPXE (undionly.kpxe or ipxe.efi)
  #   2. iPXE fetches boot.ipxe from TFTP
  #   3. boot.ipxe matches MAC → jumps to machine label
  #   4. Machine label loads kernel+initrd from the right directory
  #      (either <name>/ for talos or inspector/ for inspector mode)
  #   5. Unknown MACs drop to iPXE shell
  #
  bootScript =
    let
      # MAC → goto label routing
      macCases = lib.concatStringsSep "\n" (concatMap (entry:
        map (mac:
          let normalizedMac = toLower mac;
          in "iseq \${net0/mac} ${normalizedMac} && goto ${entry.machine.name} ||"
        ) (allMacsFor entry)
      ) cfg.machines);

      # Per-machine boot blocks
      machineBlocks = concatMapStringsSep "\n" (entry:
        let
          dir = if entry.mode == "inspector"
                then "inspector"
                else entry.machine.name;
          cmdline = if entry.mode == "inspector"
                    then cfg.inspectorKernelCmdline
                    else cfg.talosKernelCmdline;
          label = if entry.mode == "inspector"
                  then "inspector"
                  else entry.machine.name;
        in ''
          :${entry.machine.name}
          echo Booting ${entry.machine.name} [${entry.mode}]...
          kernel tftp://${cfg.ip}/${dir}/vmlinuz ${cmdline}
          initrd tftp://${cfg.ip}/${dir}/initrd
          boot
        ''
      ) cfg.machines;
    in
    pkgs.writeText "boot.ipxe" ''
      #!ipxe
      dhcp
      echo ${cfg.bootMessage}

      # Route by MAC address
      ${macCases}

      # Fallback — unknown MAC
      echo Unknown machine: ''${net0/mac}
      shell

      ${machineBlocks}
    '';

  # ── TFTP directory layout (systemd-tmpfiles rules) ────────────
  #
  # /var/lib/tftpboot/
  # ├── ipxe.efi
  # ├── undionly.kpxe
  # ├── boot.ipxe
  # ├── inspector/
  # │   ├── vmlinuz
  # │   └── initrd
  # ├── control/
  # │   ├── vmlinuz
  # │   └── initrd
  # ├── worker1/
  # │   ├── vmlinuz
  # │   └── initrd
  # └── ...
  #
  tftpRules =
    # Base files
    [
      "d /var/lib/tftpboot 0755 root root -"
      "L+ /var/lib/tftpboot/ipxe.efi - - - - ${pkgs.ipxe}/ipxe.efi"
      "L+ /var/lib/tftpboot/undionly.kpxe - - - - ${pkgs.ipxe}/undionly.kpxe"
      "L+ /var/lib/tftpboot/boot.ipxe - - - - ${bootScript}"
    ]
    # Inspector image (always present when module is enabled)
    ++ [
      "d /var/lib/tftpboot/inspector 0755 root root -"
      "L+ /var/lib/tftpboot/inspector/vmlinuz - - - - ${cfg.inspectorImage}/vmlinuz"
      "L+ /var/lib/tftpboot/inspector/initrd - - - - ${cfg.inspectorImage}/initrd"
    ]
    # Per-machine Talos images (only for machines in talos mode —
    # inspector-mode machines reuse the shared inspector/ dir)
    ++ concatMap (entry:
      if entry.mode == "talos" then [
        "d /var/lib/tftpboot/${entry.machine.name} 0755 root root -"
        "L+ /var/lib/tftpboot/${entry.machine.name}/vmlinuz - - - - ${entry.image}/vmlinuz"
        "L+ /var/lib/tftpboot/${entry.machine.name}/initrd - - - - ${entry.image}/initrd"
      ] else
        # inspector mode — no per-machine dir needed
        []
    ) cfg.machines;

in
{
  options.lab-setup.pxe = {
    enable = mkEnableOption "PXE boot server for Talos machines";

    # ── Network identity ────────────────────────────────────────
    ip = mkOption {
      type = types.str;
      description = "IP address of this PXE/DHCP/TFTP server";
    };

    interface = mkOption {
      type = types.str;
      default = "enp1s0";
      description = "Network interface dnsmasq listens on";
    };

    # ── Machine inventory ───────────────────────────────────────
    machines = mkOption {
      type = types.listOf pxeMachineType;
      default = [];
      description = "Talos machines to PXE boot, each with image and boot mode";
    };

    # ── Inspector ───────────────────────────────────────────────
    inspectorImage = mkOption {
      type = types.package;
      description = ''
        Inspector netboot assets (derivation with vmlinuz + initrd).
        Build from the inspector nixosConfiguration's netboot output.
      '';
    };

    inspectorKernelCmdline = mkOption {
      type = types.str;
      default = "console=tty0";
      description = "Kernel command line for the inspector image";
    };

    # ── Talos PXE settings ──────────────────────────────────────
    talosKernelCmdline = mkOption {
      type = types.str;
      default = lib.concatStringsSep " " [
        "talos.platform=metal"
        "console=tty0"
        "init_on_alloc=1"
        "slab_nomerge"
        "pti=on"
        "consoleblank=0"
        "nvme_core.io_timeout=4294967295"
        "printk.devkmsg=on"
      ];
      description = "Kernel command line for Talos PXE boot";
    };

    bootMessage = mkOption {
      type = types.str;
      default = "lab-setup PXE boot server";
      description = "Message displayed during iPXE boot";
    };

    # ── DNS / DHCP tunables ─────────────────────────────────────
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

    extraDhcpHosts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional static dhcp-host entries beyond the machine inventory";
    };

    extraAddresses = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra dnsmasq address= entries";
    };
  };

  # ════════════════════════════════════════════════════════════════
  # Implementation
  # ════════════════════════════════════════════════════════════════
  config = mkIf cfg.enable {

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
        dhcp-host = (concatMap mkDhcpHosts cfg.machines) ++ cfg.extraDhcpHosts;
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
      allowedUDPPorts = [ 53 67 69 ];
    };

    # ── TFTP directory tree ─────────────────────────────────────
    systemd.tmpfiles.rules = tftpRules;
  };
}
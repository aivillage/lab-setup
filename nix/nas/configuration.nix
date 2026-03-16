{ config, pkgs, inputs, ... }:
  let
    ip = "10.211.0.10";
    control = {
      host = "control";

      ip1 = "10.211.0.20";
      ip2 = "10.211.0.21";
      mac1 = "38:05:25:34:33:03";
      mac2 = "38:05:25:34:33:04";

      slowIp1 = "10.211.0.30";
      slowIp2 = "10.211.0.31";
      slowMac1 = "38:05:25:34:33:01";
      slowMac2 = "38:05:25:34:33:02";
    };
    workers = [
      {
        host = "worker1";

        ip1 = "10.211.0.22";
        ip2 = "10.211.0.23";
        mac1 = "58:47:ca:7f:54:64";
        mac2 = "58:47:ca:7f:54:65";

        slowIp1 = "10.211.0.32";
        slowIp2 = "10.211.0.33";
        slowMac1 = "58:47:ca:7f:54:67";
        slowMac2 = "58:47:ca:7f:54:65";
      }
      {
        host = "worker2";

        ip1 = "10.211.0.24";
        ip2 = "10.211.0.25";
        mac1 = "38:05:25:31:07:bd";
        mac2 = "38:05:25:31:07:bb";

        slowIp1 = "10.211.0.34";
        slowIp2 = "10.211.0.35";
        slowMac1 = "38:05:25:31:07:bc";
        slowMac2 = "38:05:25:31:07:bd";
      }
      {
        host = "worker3";

        ip1 = "10.211.0.26";
        ip2 = "10.211.0.27";
        mac1 = "58:47:ca:7e:f0:ec";
        mac2 = "58:47:ca:7e:f0:ed";

        slowIp1 = "10.211.0.36";
        slowIp2 = "10.211.0.37";
        slowMac1 = "58:47:ca:7e:f0:ee";
        slowMac2 = "58:47:ca:7e:f0:ef";
      }
    ];
    inspectorBuild = inputs.self.nixosConfigurations.inspector.config.system.build;

    talosImages = import ./talos-image.nix { 
      inherit pkgs; 
    } {
      version = "v1.12.1";
      platform = "metal";
      arch = "amd64";
      systemExtensions = [
        "siderolabs/amd-ucode"
        "siderolabs/intel-ucode"
        "siderolabs/nvidia-container-toolkit-lts"
        "siderolabs/nvidia-open-gpu-kernel-modules-lts"
      ];
      sha256 = "sha256-ctKKY9stHhMosgyKCDWQVMzOxv0wPnqsRitZlkhxYpY=";
      # sha256 = pkgs.lib.fakeHash;

      diskImage = "pxe-assets";
    };
  in
{
  imports =
    [
      ./hardware-configuration.nix
    ];

  # ==========================================
  # 1. Boot & System Basics
  # ==========================================
  
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "cluster-control";
  networking.hostId = "8425e349"; 

  # ==========================================
  # 2. ZFS & NFS Configuration
  # ==========================================
  
  boot.supportedFilesystems = [ "zfs" ];
  services.zfs.autoScrub.enable = true;

  fileSystems."/mnt/data" = {
    device = "tank/share";
    fsType = "zfs";
    options = [ "zfsutil" ]; 
  };

    services.nfs.server = {
    enable = true;
    # 1. rw: Read/Write
    # 2. insecure: Allows ports > 1024 (Crucial for macOS/Windows clients)
    # 3. all_squash: Map ALL users to the anonymous user (nobody)
    # 4. anonuid/anongid: Explicitly define the anonymous ID (65534 is standard 'nobody')
    exports = ''
      /mnt/data 10.211.0.0/24(rw,nohide,insecure,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
    '';
  };

  # ==========================================
  # 3. Networking & Firewall
  # ==========================================
  
  networking.interfaces.enp1s0.ipv4.addresses = [{
    address = ip;
    prefixLength = 24;
  }];
  networking.defaultGateway = "10.211.0.1";
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  services.tailscale = {
    enable = true;
    authKeyFile = "/var/keys/tailscale_key";
    extraUpFlags = [ "--ssh" ];
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    
    allowedTCPPorts = [ 
      22   # Local ssh
      53   # DNS (dnsmasq)
      2049 # NFS
    ]; 
    allowedUDPPorts = [ 
      53   # DNS
      67   # DHCP
      69   # TFTP
    ];
  };

  # ==========================================
  # 4. SSH Configuration
  # ==========================================
  
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ==========================================
  # 6. User Account
  # ==========================================

  security.sudo.wheelNeedsPassword = false;

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai" 
    ];
  };

  # ==========================================
  # 7. Utilities
  # ==========================================
  environment.systemPackages = with pkgs; [
    vim
    wget
    nano
    talosctl
    kubectl
    git
    htop
    zfs
    zsh
    k9s
    cilium-cli
    hubble
    nmap
    tcpdump
  ];
  # ==========================================
  # 8. Main DHCP & DNS (Pure Dnsmasq PXE)
  # ==========================================

  services.resolved.enable = false;

  services.dnsmasq = {
    enable = true;
    alwaysKeepRunning = true; 
    
    settings = {
      interface = [ "enp1s0" ];
      bind-interfaces = true; 
      log-dhcp = true;

      # DNS
      domain-needed = true;
      bogus-priv = true;
      server = [ "1.1.1.1" "8.8.8.8" ];
      expand-hosts = true;
      domain = "cluster.local";

      # DHCP Subnet
      dhcp-range = [ "10.211.0.100,10.211.0.200,255.255.255.0,24h" ];

      # Options
      dhcp-option = [
        "option:router,10.211.0.1"
        "option:dns-server,${ip}"
      ];

      # Static Hosts
      dhcp-host = [
        "${control.mac1},${control.ip1},${control.host}"
        "${control.mac2},${control.ip2},${control.host}"
        "${control.slowMac1},${control.slowIp1},${control.host}"
        "${control.slowMac2},${control.slowIp2},${control.host}"
      ] ++ (builtins.concatMap (w: [
        "${w.mac1},${w.ip1},${w.host}"
        "${w.mac2},${w.ip2},${w.host}"
        "${w.slowMac1},${w.slowIp1},${w.host}"
        "${w.slowMac2},${w.slowIp2},${w.host}"
      ]) workers);
      address = [ 
        "/nas/${ip}"
        "/.aiv.local/10.211.0.50"
      ];

      # ==========================================
      # TFTP & PXE Configuration
      # ==========================================
      enable-tftp = true;
      tftp-root = "/var/lib/tftpboot";

      # 1. Tagging: Detect if the client is BIOS (Legacy), UEFI, or iPXE
      dhcp-match = [
        "set:efi-x86_64,option:client-arch,7"
        "set:efi-x86_64,option:client-arch,9"
        "set:ipxe,175" # iPXE sends option 175
      ];

      # 2. Boot Logic (Chainloading)
      # If the client is NOT iPXE yet (!ipxe), send the iPXE bootloader.
      dhcp-boot = [
        "tag:!ipxe,tag:!efi-x86_64,undionly.kpxe"  # Legacy BIOS -> load undionly.kpxe
        "tag:!ipxe,tag:efi-x86_64,ipxe.efi"        # UEFI -> load ipxe.efi
        "tag:ipxe,boot.ipxe"                       # If iPXE is running -> load script
      ];
    };
  };

  # ==========================================
  # 9. PXE Files Setup (The "Plumbing")
  # ==========================================
  systemd.tmpfiles.rules = import ./pxe-boot.nix {
    inherit pkgs ip;
    message    = "Starting Talos Boot...";
    kernelPath = "${talosImages}/vmlinuz";  # Talos outputs 'vmlinuz'
    initrdPath = "${talosImages}/initrd";
    cmdline    = "talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1";
  } ++ [
    # From Section 2 (ZFS) permit everyone
    "z /mnt/data 0777 nobody nogroup -"
  ];

  # systemd.tmpfiles.rules = import ./pxe-boot.nix {
  #   inherit pkgs;
  #   ip = ip;
  #   message    = "Starting Inspector Boot...";
  #   kernelPath = "${inspectorBuild.kernel}/bzImage"; # NixOS outputs 'bzImage'
  #   initrdPath = "${inspectorBuild.netbootRamdisk}/initrd";
  #   cmdline    = "init=${inspectorBuild.toplevel}/init loglevel=4";
  # } ++ [
  #   # From Section 2 (ZFS) permit everyone
  #   "z /mnt/data 0777 nobody nogroup -"
  # ];

  system.stateVersion = "25.11";
}
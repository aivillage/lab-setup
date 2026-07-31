{
  pkgs,
  inputs,
  ip,
  machines,
  inspector,
  wipe ? false,
}:
let
  lib = pkgs.lib;
  generatePatches = (import ../talos { inherit pkgs lib inputs; }).mkGeneratePatches {
    webserverHost = "http://${ip}:8080/configs";
  };
  message = if wipe then "WIPING ALL DATA" else "Booting inspector...";
  # cmdline = if wipe then "talos.platform=metal" else "talos.platform=metal"; # Placeholder if needed

  wipeScript = pkgs.writeText "wipe.ipxe" ''
    #!ipxe
    dhcp
    echo ${message}
    kernel tftp://${ip}/default/bzImage init=${inspector.toplevel}/init loglevel=4
    initrd tftp://${ip}/default/initrd
    boot
  '';

  bootScript =
    if wipe then
      wipeScript
    else
      let
        macCases = lib.concatStringsSep "\n" (
          lib.concatMap (
            m:
            lib.mapAttrsToList (
              _name: iface:
              let
                normalizedMac = lib.toLower iface.mac;
              in
              "iseq \${net0/mac} ${normalizedMac} && goto ${m.name} ||"
            ) m.machine.network-interfaces
          ) machines
        );

        machineBlocks = lib.concatMapStringsSep "\n" (m:
          if (m.wipe or (m.machine.wipe or false)) then ''
            :${m.name}
            echo "WIPING DATA FOR ${m.name}..."
            kernel tftp://${ip}/default/bzImage init=${inspector.toplevel}/init loglevel=4 inspector.server=http://${ip}:8080
            initrd tftp://${ip}/default/initrd
            boot
          '' else ''
            :${m.name}
            echo Booting ${m.name}...
            kernel tftp://${ip}/${m.name}/vmlinuz talos.config=http://${ip}:8080/configs/${m.name}.yaml talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1
            initrd tftp://${ip}/${m.name}/initrd
            boot
          ''
        ) machines;
      in
      pkgs.writeText "boot.ipxe" ''
        #!ipxe
        dhcp
        echo "Booting Talos nodes..."

        # Route by MAC address
        ${macCases}

        # Fallback — unknown MAC
        echo Unknown machine: ''${net0/mac}
        goto default

        ${machineBlocks}

        :default
          echo Booting default...
          kernel tftp://${ip}/default/bzImage init=${inspector.toplevel}/init initrd=initrd inspector.server=http://${ip}:8080 loglevel=4
          initrd tftp://${ip}/default/initrd
          boot
      '';
  emptySyslinux = pkgs.runCommand "empty-syslinux" { } ''
    mkdir -p "$out/share/syslinux"
  '';

  ipxeBase =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      pkgs.ipxe
    else
      (import pkgs.path {
        system = pkgs.stdenv.hostPlatform.system;
        crossSystem = "x86_64-linux";
        config.allowUnsupportedSystem = true;
      }).ipxe;

  ipxePkg =
    (ipxeBase.override {
      enableDefaultPlatformTargets = false;

      additionalTargets = {
        "bin-x86_64-efi/ipxe.efi" = "ipxe.efi";
      };

      firmwareBinary = "ipxe.efi";

      syslinux = emptySyslinux;
    }).overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        rm -f "$out/undionly.kpxe.0"
      '';
    });
  ipxeWithEmbeddedScript = ipxePkg.override {
    embedScript = pkgs.writeText "autoexec.ipxe" ''
      #!ipxe
      :retry
      dhcp || goto retry
      echo Booting iPXE autoexec...
      chain --autofree tftp://${ip}/boot.ipxe
    '';
  };
in
[
  "d /var/lib/tftpboot 0755 root root -"
  "L+ /var/lib/tftpboot/ipxe.efi - - - - ${ipxeWithEmbeddedScript}/ipxe.efi"
  "L+ /var/lib/tftpboot/boot.ipxe - - - - ${bootScript}"
  "d /var/lib/tftpboot/default 0755 root root -"
  "L+ /var/lib/tftpboot/default/bzImage - - - - ${inspector.kernel}/bzImage"
  "L+ /var/lib/tftpboot/default/initrd - - - - ${inspector.netbootRamdisk}/initrd"
  "d /var/lib/tftpboot/configs 0755 root root -"
  "L+ /var/lib/tftpboot/configs/generate-patches - - - - ${generatePatches}"
]
# Per-machine kernel + initrd + configScript directories
++ (lib.concatMap (m: [
  "d /var/lib/tftpboot/${m.name} 0755 root root -"
  "L+ /var/lib/tftpboot/${m.name}/vmlinuz - - - - ${m.image}/vmlinuz"
  "L+ /var/lib/tftpboot/${m.name}/initrd - - - - ${m.image}/initrd"
  "L+ /var/lib/tftpboot/configs/${m.name}.yaml - - - - ${m.configScript}"
]) machines)

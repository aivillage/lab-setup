{
  pkgs,
  ip,
  machines,
  inspector,
  wipe ? false,
}:
let
  lib = pkgs.lib;
  message = if wipe then "WIPING ALL DATA" else "Booting inspector...";
  cmdline = if wipe then "talos.platform=metal" else "talos.platform=metal"; # Placeholder if needed

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

        machineBlocks = lib.concatMapStringsSep "\n" (m: ''
          :${m.name}
          echo Booting ${m.name}...
          kernel tftp://${ip}/${m.name}/vmlinuz talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1
          initrd tftp://${ip}/${m.name}/initrd
          boot
        '') machines;
      in
      pkgs.writeText "boot.ipxe" ''
        #!ipxe
        dhcp
        echo "Booting Talos nodes..."

        # Route by MAC address
        ${macCases}

        # Fallback — unknown MAC
        echo Unknown machine: ''${net0/mac}
        shell

        ${machineBlocks}

        :default
          echo Booting default...
          kernel tftp://${ip}/default/bzImage
          initrd tftp://${ip}/default/initrd
          boot
      '';
in
[
  "d /var/lib/tftpboot 0755 root root -"
  "L+ /var/lib/tftpboot/ipxe.efi - - - - ${pkgs.ipxe}/ipxe.efi"
  "L+ /var/lib/tftpboot/undionly.kpxe - - - - ${pkgs.ipxe}/undionly.kpxe"
  "L+ /var/lib/tftpboot/boot.ipxe - - - - ${bootScript}"
  "d /var/lib/tftpboot/default 0755 root root -"
  "L+ /var/lib/tftpboot/default/bzImage - - - - ${inspector.kernel}/bzImage"
  "L+ /var/lib/tftpboot/default/initrd - - - - ${inspector.netbootRamdisk}/initrd"
]
# Per-machine kernel + initrd directories
++ (lib.concatMap (m: [
  "d /var/lib/tftpboot/${m.name} 0755 root root -"
  "L+ /var/lib/tftpboot/${m.name}/vmlinuz - - - - ${m.image}/vmlinuz"
  "L+ /var/lib/tftpboot/${m.name}/initrd - - - - ${m.image}/initrd"
]) machines)

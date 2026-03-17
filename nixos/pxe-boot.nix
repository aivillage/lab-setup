{ pkgs, ip, kernelPath, initrdPath, cmdline, message }:
let
  bootScript = pkgs.writeText "boot.ipxe" ''
    #!ipxe
    dhcp
    echo ${message}
    kernel tftp://${ip}/kernel ${cmdline}
    initrd tftp://${ip}/initrd
    boot
  '';
in
[
  "d /var/lib/tftpboot 0755 root root -"
  "L+ /var/lib/tftpboot/ipxe.efi - - - - ${pkgs.ipxe}/ipxe.efi"
  "L+ /var/lib/tftpboot/undionly.kpxe - - - - ${pkgs.ipxe}/undionly.kpxe"
  "L+ /var/lib/tftpboot/kernel - - - - ${kernelPath}"
  "L+ /var/lib/tftpboot/initrd - - - - ${initrdPath}"
  "L+ /var/lib/tftpboot/boot.ipxe - - - - ${bootScript}"
  "z /mnt/data 0777 nobody nogroup -"
]
{ pkgs, ip, talos-machines, inspector-pxe }:
let
  bootScript = let
    macCases = lib.concatStringsSep "\n" (lib.concatMap (m:
      map (mac:
        let normalizedMac = lib.toLower mac;
        in "iseq \${net0/mac} ${normalizedMac} && goto ${m.name} ||"
      ) m.allMacs
    ) talos-machines);

    machineBlocks = lib.concatMapStringsSep "\n" (m: ''
      :${m.name}
      echo Booting ${m.name}...
      kernel tftp://${cfg.ip}/${m.name}/vmlinuz ${cfg.pxe.kernelCmdline}
      initrd tftp://${cfg.ip}/${m.name}/initrd
      boot
    '') talos-machines;
  in
  pkgs.writeText "boot.ipxe" ''
    #!ipxe
    dhcp
    echo ${cfg.pxe.bootMessage}

    # Route by MAC address
    ${macCases}

    # Fallback — unknown MAC
    echo Unknown machine: ''${net0/mac}
    shell

    ${machineBlocks}
  '';
in
[
    "d /var/lib/tftpboot 0755 root root -"
    "L+ /var/lib/tftpboot/ipxe.efi - - - - ${pkgs.ipxe}/ipxe.efi"
    "L+ /var/lib/tftpboot/undionly.kpxe - - - - ${pkgs.ipxe}/undionly.kpxe"
    "L+ /var/lib/tftpboot/boot.ipxe - - - - ${bootScript}"
  ]
  # Per-machine kernel + initrd directories
  ++ (lib.concatMap (m: [
    "d /var/lib/tftpboot/${m.name} 0755 root root -"
    "L+ /var/lib/tftpboot/${m.name}/vmlinuz - - - - ${m.image}/vmlinuz"
    "L+ /var/lib/tftpboot/${m.name}/initrd - - - - ${m.image}/initrd"
  ]) talos-machines)
 ++ [
  "z ${cfg.zfs.mountPoint} 0777 nobody nogroup -"
]
{
  pkgs,
  inputs,
  ip,
  machines,
  inspector,
  generatePatches ? null,
}:
let
  lib = pkgs.lib;
  resolvedGeneratePatches = if generatePatches != null then generatePatches else (import ../talos { inherit pkgs lib inputs; }).mkGeneratePatches {
    coordinatorIp = ip;
    webserverHost = "http://${ip}:8080/configs";
  };

  bootScript = pkgs.writeText "boot.ipxe" ''
    #!ipxe
    chain http://${ip}:8080/boot.ipxe?mac=''${net0/mac}
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
  "L+ /var/lib/tftpboot/default/netboot.ipxe - - - - ${inspector.netbootIpxeScript}/netboot.ipxe"
  "r /var/lib/tftpboot/configs/* - - - - -"
  "d /var/lib/tftpboot/configs 0755 root root -"
  "L+ /var/lib/tftpboot/configs/generate-patches - - - - ${resolvedGeneratePatches}"
  "d /var/lib/coordinator/talos 0755 root root -"
  "Z /var/lib/coordinator/talos 0755 root root -"
  "z /var/lib/coordinator/talos/* 0644 root root -"
]
# Per-machine kernel + initrd + configScript directories
++ (lib.concatMap (m: [
  "d /var/lib/tftpboot/${m.name} 0755 root root -"
  "L+ /var/lib/tftpboot/${m.name}/vmlinuz - - - - ${m.image}/vmlinuz"
  "L+ /var/lib/tftpboot/${m.name}/initrd - - - - ${m.image}/initrd"
  "L+ /var/lib/tftpboot/configs/${m.name}.yaml - - - - ${m.configScript}"
]) machines)

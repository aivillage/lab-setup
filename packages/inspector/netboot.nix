{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages = inputs.nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
        inspector-netboot =
          let
            inspectorSystem = inputs.nixpkgs.lib.nixosSystem {
              specialArgs = { inherit inputs; };
              modules = [
                {
                  nixpkgs.buildPlatform = system;
                  nixpkgs.hostPlatform = "x86_64-linux";
                  networking.hostName = "inspector";
                }
                (inputs.nixpkgs + "/nixos/modules/installer/netboot/netboot-minimal.nix")
                inputs.self.nixosModules.inspector
                {
                  inspector.authorizedKeys = (import ../../keys.nix).all;
                }
                ({ config, pkgs, lib, ... }: {
                  system.build.netbootIpxeScript = lib.mkForce (pkgs.writeTextDir "netboot.ipxe" ''
                    #!ipxe
                    kernel bzImage init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams} ''${cmdline}
                    initrd initrd
                    boot
                  '');
                })
              ];
            };
          in
          pkgs.symlinkJoin {
            name = "inspector-netboot";
            paths = [
              inspectorSystem.config.system.build.kernel
              inspectorSystem.config.system.build.netbootRamdisk
              inspectorSystem.config.system.build.netbootIpxeScript
            ];
          };
      };
    };
}

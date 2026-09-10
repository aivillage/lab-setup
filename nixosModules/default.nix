{ inputs }:
{
  base = { ... }: {
    imports = [
      ./base.nix
      inputs.sops-nix.nixosModules.sops
    ];
    _module.args.inputs = inputs;
  };

  shell = ./shell.nix;
  admin = ./admin.nix;

  secrets = { ... }: {
    imports = [
      ./secrets.nix
      inputs.sops-nix.nixosModules.sops
    ];
  };

  inspector = { ... }: {
    imports = [ ./inspector ];
    nixpkgs.overlays = [
      (final: prev: {
        inspector = inputs.self.packages.${final.stdenv.hostPlatform.system}.inspector;
      })
    ];
  };

  inspector-iso = ./inspector/iso.nix;
  spark = ./spark;
  spark-iso = ./spark/iso.nix;

  coordinator = {
    imports = [ ./coordinator ];
    _module.args.inputs = inputs;
    _module.args.inspector = (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${inputs.nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
        inputs.self.nixosModules.inspector
      ];
    });
  };

  vllm = ./vllm.nix;
}

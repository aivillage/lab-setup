{ inputs }:
let
  labSetupInputs = inputs;
in
{
  base = { inputs ? null, ... }: {
    imports = [
      ./base.nix
      labSetupInputs.sops-nix.nixosModules.sops
    ];
    _module.args.inputs = labSetupInputs // (if inputs != null then inputs else { });
  };

  shell = ./shell.nix;
  admin = ./admin.nix;

  secrets = { ... }: {
    imports = [
      ./secrets.nix
      labSetupInputs.sops-nix.nixosModules.sops
    ];
  };

  inspector = { ... }: {
    imports = [ ./inspector ];
    nixpkgs.overlays = [
      (final: prev: {
        inspector = labSetupInputs.self.packages.${final.stdenv.hostPlatform.system}.inspector;
      })
    ];
  };

  inspector-iso = ./inspector/iso.nix;
  spark = ./spark;
  spark-iso = ./spark/iso.nix;

  coordinator = { inputs ? null, ... }: {
    imports = [ ./coordinator ];
    _module.args.inputs = labSetupInputs // (if inputs != null then inputs else { });
    _module.args.inspector = (labSetupInputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        "${labSetupInputs.nixpkgs}/nixos/modules/installer/netboot/netboot-minimal.nix"
        labSetupInputs.self.nixosModules.inspector
      ];
    });
  };

  vllm = ./vllm.nix;
}

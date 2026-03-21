{
  pkgs,
  lib,
  inputs,
  nfsServer,
  mainPath,
  vllmPath,
  ...
}:
let
  kubelib = inputs.nix-kube-generators.lib { inherit pkgs; };

  ciliumFile = import ./cilium.nix {
    inherit pkgs kubelib;
  };
  ghcrAuthFile = import ./ghcr.nix {
    inherit pkgs;
  };
  mainPcvFile = import ./nfs.nix {
    inherit pkgs kubelib;
    server = nfsServer;
    path = mainPath;
  };
  nvidia = import ./nvidia.nix {
    inherit pkgs kubelib;
  };

in
{
  all = [
    ciliumFile
    ghcrAuthFile
    mainPcvFile
    modelPvcFile
    nvidia.helmPatch
    nvidia.runtimeClassPatch
  ];

  inherit nvidia;
}

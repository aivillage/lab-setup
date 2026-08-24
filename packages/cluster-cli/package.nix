{
  perSystem =
    {
      pkgs,
      ...
    }:
    let
      clusterCli = import ./default.nix { inherit pkgs; coordinator = "127.0.0.1"; };
    in
    {
      packages.cluster-cli = clusterCli;
      packages.cluster = clusterCli;
    };
}

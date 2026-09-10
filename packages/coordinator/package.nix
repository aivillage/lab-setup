{
  perSystem =
    {
      pkgs,
      ...
    }:
    let
      coordinator = pkgs.python3Packages.callPackage ./default.nix { };
    in
    {
      packages.coordinator = coordinator;
    };
}

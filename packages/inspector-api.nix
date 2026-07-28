{
  perSystem =
    { pkgs, ... }:
    {
      packages.inspector-api = pkgs.writers.writePython3Bin "inspector-api" {
        doCheck = false;
      } (builtins.readFile ./inspector-api/server.py);
    };
}

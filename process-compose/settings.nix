{ pkgs, ... }:
{
  # these are effectively just constants, want to establish a single soure of truth
  aiv-lab =
    let
      baseDataDir = ".data"; # based on $PWD
      host = if pkgs.stdenv.isDarwin then "host.docker.internal" else "10.5.0.1";
    in
    {
      inherit baseDataDir;
      inherit host;
      webserver = {
        storagePath = baseDataDir + "/webserver";
        port = 5555;
      };
      registries = {
        storagePath = baseDataDir + "/registries";
      };
      patches = {
        storagePath = baseDataDir + "/talos-patches";
      };
      talos = {
        version = "v1.13.3";
        storagePath = baseDataDir + "/talos";
      };
    };
}

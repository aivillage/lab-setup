{
  pkgs ? import <nixpkgs> { },
}:

let
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    fastapi
    uvicorn
    pydantic
    pydantic-settings
    pyyaml
    filelock
    jinja2
  ]);
in
pkgs.stdenv.mkDerivation {
  pname = "coordinator";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/libexec $out/bin
    cp -r src/coordinator $out/libexec/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/coordinator \
      --set PYTHONPATH "$out/libexec" \
      --add-flags "-m coordinator.main"
  '';

  meta = {
    description = "AI Village Cluster Coordinator Service";
    mainProgram = "coordinator";
  };
}

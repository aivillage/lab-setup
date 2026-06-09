{
  perSystem =
    {
      pkgs,
      system,
      inputs',
      ...
    }:
    {
      packages.inspector =
        let
          # Grab fenix directly from the evaluated system inputs
          rustToolchain = inputs'.fenix.packages.stable.minimalToolchain;

          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
        in
        rustPlatform.buildRustPackage {
          pname = "inspector";
          version = "0.1.0";

          # Note: Ensure this relative path correctly points to the
          # root of your Rust workspace from where this file lives.
          src = ../.;
          cargoLock.lockFile = ../Cargo.lock;

          buildInputs = [ pkgs.openssl ];

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.openssl
            pkgs.cmake
            pkgs.makeWrapper
          ];

          buildAndTestSubdir = "crates/inspector";

          env.LD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}";

          cargoBuildFlags = [
            "-p"
            "inspector"
          ];

          doCheck = false;

          postInstall = ''
            wrapProgram $out/bin/inspector \
              --prefix PATH : ${
                pkgs.lib.makeBinPath [
                  pkgs.util-linux
                  pkgs.gptfdisk
                  pkgs.coreutils
                ]
              }
          '';

          meta.mainProgram = "inspector";
        };
    };
}

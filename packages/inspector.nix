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
        pkgs.rustPlatform.buildRustPackage {
          pname = "inspector";
          version = "0.1.0";
          auditable = false;

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

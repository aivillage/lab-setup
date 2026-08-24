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

          src = pkgs.lib.fileset.toSource {
            root = ../../.;
            fileset = pkgs.lib.fileset.unions [
              ../../Cargo.toml
              ../../Cargo.lock
              ../../crates/inspector
            ];
          };
          cargoLock.lockFile = ../../Cargo.lock;

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

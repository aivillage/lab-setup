{
  pkgs ? import <nixpkgs> { },
}:
{
  version,
  sha256,
  schematic,
  diskImage ? "iso", # Options: iso, raw, qcow2, pxe, pxe-assets
  platform ? "metal",
  arch ? "amd64",
  secureboot ? false,
}:

let
  secbootSuffix = if secureboot then "-secureboot" else "";

  # 2. Configure file extensions and domains based on image type
  imageConfig =
    if diskImage == "iso" then
      {
        isDirectory = false;
        ext = ".iso";
        domain = "factory.talos.dev";
        pathPrefix = "image";
      }
    else if diskImage == "raw" then
      {
        isDirectory = false;
        ext = ".raw.zst";
        domain = "factory.talos.dev";
        pathPrefix = "image";
      }
    else if diskImage == "qcow2" then
      {
        isDirectory = false;
        ext = ".qcow2";
        domain = "factory.talos.dev";
        pathPrefix = "image";
      }
    else if diskImage == "pxe" then
      {
        # This downloads the iPXE script text file provided by Factory
        isDirectory = false;
        ext = "";
        domain = "pxe.factory.talos.dev";
        pathPrefix = "pxe";
      }
    else if diskImage == "pxe-assets" then
      {
        # NEW: Downloads kernel + initramfs into a folder
        isDirectory = true;
        ext = ""; # No single extension
        domain = "factory.talos.dev";
        pathPrefix = "image";
      }
    else
      abort "Unknown diskImage type: ${diskImage}.";

  baseName = "${platform}-${arch}${secbootSuffix}";
  fileName = "${baseName}${imageConfig.ext}";

in
pkgs.stdenvNoCC.mkDerivation {
  name = "talos-${version}-${baseName}";
  outputHashAlgo = "sha256";
  outputHash = sha256;

  # Crucial Change: Switch hash mode based on whether we expect a file or directory
  outputHashMode = if imageConfig.isDirectory then "recursive" else "flat";

  nativeBuildInputs = [
    pkgs.curl
  ];

  buildCommand = ''
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    export PATH="${pkgs.curl}/bin:$PATH"

    # --- STEP 2: Download the Assets ---

    if [ "${toString imageConfig.isDirectory}" = "1" ]; then
        # === DIRECTORY MODE (pxe-assets) ===
        echo "--> Downloading PXE assets to directory..."
        mkdir -p $out

        # Construct URLs for Kernel and Initramfs
        KERNEL_URL="https://${imageConfig.domain}/${imageConfig.pathPrefix}/${builtins.readFile schematic}/${version}/kernel-${arch}"
        INITRD_URL="https://${imageConfig.domain}/${imageConfig.pathPrefix}/${builtins.readFile schematic}/${version}/initramfs-${arch}.xz"

        echo "    Fetching Kernel: $KERNEL_URL"
        curl -L --fail --show-error --progress-bar -o $out/vmlinuz "$KERNEL_URL"

        echo "    Fetching Initramfs: $INITRD_URL"
        curl -L --fail --show-error --progress-bar -o $out/initrd "$INITRD_URL"

    else
        # === SINGLE FILE MODE (iso, raw, pxe-script) ===
        URL="https://${imageConfig.domain}/${imageConfig.pathPrefix}/${builtins.readFile schematic}/${version}/${fileName}"
        echo "--> Downloading single image from: $URL"
        curl -L --fail --show-error --progress-bar -o $out "$URL"
    fi
  '';
}

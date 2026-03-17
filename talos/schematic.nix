# Posts the schematic config to factory.talos.dev and outputs
# the resulting schematic ID as a plain text file.
# Both image.nix and config.nix consume this derivation.
#
{ pkgs }:
{
  systemExtensions ? [ ],
  extraKernelArgs ? [ ],
  meta ? [ ],
  secureboot ? false,
}:

let
  schematicConfig = {
    customization = {
      systemExtensions = {
        officialExtensions = systemExtensions;
      };
      extraKernelArgs = extraKernelArgs;
      meta = meta;
    }
    // pkgs.lib.optionalAttrs secureboot {
      secureboot = {
        includeWellKnownCertificates = true;
      };
    };
  };

  schematicJson = builtins.toJSON schematicConfig;
in
pkgs.stdenvNoCC.mkDerivation {
  name = "talos-schematic-id";
  outputHashAlgo = "sha256";
  outputHashMode = "flat";
  # Caller must supply the real hash after a first run with fakeSha256
  outputHash = ""; # placeholder — see usage in default.nix

  nativeBuildInputs = [ pkgs.curl pkgs.jq ];

  buildCommand = ''
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

    RESPONSE=$(curl -s -X POST \
      -H "Content-Type: application/json" \
      --data-binary '${schematicJson}' \
      https://factory.talos.dev/schematics)

    ID=$(echo "$RESPONSE" | jq -r '.id')

    if [ -z "$ID" ] || [ "$ID" == "null" ]; then
      echo "Error: Failed to retrieve Schematic ID."
      echo "$RESPONSE"
      exit 1
    fi

    echo -n "$ID" > $out
  '';
}
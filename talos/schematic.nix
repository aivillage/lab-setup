# lab-setup/talos/schematic.nix
#
# Registers a Talos Factory schematic for a given machine and returns
# a derivation whose $out is the schematic ID string.
#
# Called from default.nix via mkSchematic { machine, version, sha256 }.
#
{ pkgs, lib }:

let
  baseExtensions = [
    "siderolabs/amd-ucode"
    "siderolabs/intel-ucode"
  ];

  nvidiaExtensions = [
    "siderolabs/nvidia-container-toolkit-lts"
    "siderolabs/nvidia-open-gpu-kernel-modules-lts"
  ];

in
{
  mkSchematic =
    {
      machine,
      sha256 ? lib.fakeSha256,
      extraKernelArgs ? [ ],
      meta ? [ ],
      secureboot ? false,
    }:
    let
      extensions =
        baseExtensions ++ lib.optionals machine.nvidia nvidiaExtensions ++ machine.extraExtensions;

      schematicConfig = {
        customization = {
          systemExtensions.officialExtensions = extensions;
          extraKernelArgs = extraKernelArgs;
          meta = meta;
        };
      }
      // lib.optionalAttrs secureboot {
        secureboot.includeWellKnownCertificates = true;
      };

      schematicJson = builtins.toJSON schematicConfig;

    in
    pkgs.stdenvNoCC.mkDerivation {
      name = "talos-schematic-${machine.name}";
      outputHashAlgo = "sha256";
      outputHashMode = "flat";
      outputHash = sha256;

      nativeBuildInputs = [
        pkgs.curl
        pkgs.jq
      ];

      buildCommand = ''
        export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"

        echo "--> Registering Talos Schematic for ${machine.name}..."
        echo "    Config: ${schematicJson}"

        RESPONSE=$(curl -s -X POST \
          -H "Content-Type: application/json" \
          --data-binary '${schematicJson}' \
          https://factory.talos.dev/schematics)

        ID=$(echo "$RESPONSE" | jq -r '.id')

        if [ -z "$ID" ] || [ "$ID" == "null" ]; then
          echo "Error: Failed to retrieve Schematic ID. Factory response:"
          echo "$RESPONSE"
          exit 1
        fi

        echo "--> Success! Got Schematic ID: $ID"
        echo -n "$ID" > $out
      '';
    };
}

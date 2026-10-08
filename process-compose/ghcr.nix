{ pkgs }:
let
  ghcrUser = builtins.getEnv "GITHUB_USERNAME";
  ghcrToken = builtins.getEnv "GHCR_PAT";
in
pkgs.runCommand "ghcr-auth.yaml" { } ''
      # Logic runs inside the Nix build sandbox
      AUTH_STRING=$(echo -n "${ghcrUser}:${ghcrToken}" | base64 -w 0)

      cat > $out <<EOF
  machine:
    registries:
      config:
        ghcr.io:
          auth:
            auth: "$AUTH_STRING"
  EOF
''

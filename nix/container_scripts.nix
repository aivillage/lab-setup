{ pkgs }:

let
  scriptPreamble = ''
    #!/usr/bin/env bash
    set -euo pipefail # Exit on error, unset variables, and pipe failures
    
    # This script assumes it's run from within the dev shell.
    # The shellHook is expected to have already set:
    # - GITHUB_USERNAME (from .envhost)
    # - PROJECT_ROOT
    # - And already run `docker login` for ghcr.io

    if [[ -z "''${PROJECT_ROOT:-}" ]]; then
      echo "Error: PROJECT_ROOT is not set. Are you in the dev shell?"
      exit 1
    fi
  '';
  
  # Helper to generate a single script for one container
  mkOneScript = { name, path, type ? "docker" }:
    let
      scriptName = "upload-${name}";
      
      # 1. Standard Docker Build Logic (Default)
      # Uses 'path' as the context directory relative to PROJECT_ROOT
      dockerBody = ''
        echo "--- Processing image: ${name} ---"
        LOCAL_TAG="${name}:latest"
        REMOTE_TAG="ghcr.io/nbhdai/${name}:latest"
        CONTEXT_PATH="$PROJECT_ROOT/${path}"

        echo "Building $LOCAL_TAG from $CONTEXT_PATH..."
        docker build -t "$LOCAL_TAG" "$CONTEXT_PATH"
        
        echo "Tagging $LOCAL_TAG as $REMOTE_TAG..."
        docker tag "$LOCAL_TAG" "$REMOTE_TAG"
        
        echo "Pushing $REMOTE_TAG..."
        docker push "$REMOTE_TAG"
        echo "Successfully pushed $REMOTE_TAG"
        echo "-----------------------------------"
      '';

      # 2. Nix Build Logic
      # Uses 'path' as the flake attribute name (e.g., "workshop-hub")
      nixBody = ''
        echo "--- Processing image: ${name} ---"
        LOCAL_TAG="${name}:latest"
        REMOTE_TAG="ghcr.io/nbhdai/${name}:latest"
        RESULT_LINK="result-${name}"

        echo "Building Nix attribute: ${path}..."
        nix build "$PROJECT_ROOT#${path}" --out-link "$RESULT_LINK"
        
        echo "Loading $LOCAL_TAG into Docker..."
        docker load < "$RESULT_LINK"
        
        echo "Tagging $LOCAL_TAG as $REMOTE_TAG..."
        docker tag "$LOCAL_TAG" "$REMOTE_TAG"
        
        echo "Pushing $REMOTE_TAG..."
        docker push "$REMOTE_TAG"
        
        rm "$RESULT_LINK"
        echo "Successfully pushed $REMOTE_TAG"
        echo "-----------------------------------"
      '';
      
      scriptBody = if type == "docker" then dockerBody else nixBody;
    in
      pkgs.writeShellScriptBin scriptName (scriptPreamble + scriptBody);

  # Helper to generate the composite 'upload-all-images' script
  mkAllScript = containers:
    let
      # Generate calls like: echo "..." && upload-name
      calls = map (c: ''
        echo "Triggering upload-${c.name}..."
        upload-${c.name}
      '') containers;
    in
      pkgs.writeShellScriptBin "upload-all-images" ''
        ${scriptPreamble}
        echo "=== 🚀 Starting upload for all images... ==="
        echo ""
        ${builtins.concatStringsSep "\n" calls}
        echo ""
        echo "=== ✅ All images pushed successfully! ==="
      '';

in
  # The main function: takes a list of containers, returns a list of script packages
  containers: (map mkOneScript containers) ++ [ (mkAllScript containers) ]
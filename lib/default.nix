{ lib }:
let
  allFiles = lib.filesystem.listFilesRecursive ./.;

  # Filter out non-Nix files and the default.nix file itself
  nixFiles = builtins.filter (
    path: lib.hasSuffix ".nix" (builtins.toString path) && baseNameOf path != "default.nix"
  ) allFiles;

  functions = lib.foldl' (acc: path: acc // (import path { inherit lib; })) { } nixFiles;
in
functions

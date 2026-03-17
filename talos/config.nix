{ pkgs, lib, inputs, clusterName, talosVersion, vIp, nfsServer, mainPath, vllmPath, ... }:

let
  clusterEndpoint = "https://${vIp}:6443";
  patchesSet = import ./patches/manifest.nix { inherit pkgs lib inputs nfsServer mainPath vllmPath; };
  patchFlags = lib.concatMapStringsSep " " (p: "--config-patch @${p}") patchesSet.all;
  controlPatchFlags = lib.concatMapStringsSep " " (p: "--config-patch-control-plane @${p}") patchesSet.control;
  workerPatchFlags = lib.concatMapStringsSep " " (p: "--config-patch-worker @${p}") patchesSet.worker;
in
pkgs.writeShellScriptBin "generate-talos-configs" ''
  set -e

  if [ $# -eq 1 ]; then
    SECRETS_FLAG="--with-secrets $1"
  else
    SECRETS_FLAG=""
  fi
  if [ $# -eq 2 ]; then
    SECRETS_FLAG="--with-secrets $1"
    OUTPUT_FLAG="--output $2"
  else
    OUTPUT_FLAG=""
  fi

  ${pkgs.talosctl}/bin/talosctl gen config \
    "${clusterName}" \
    "${clusterEndpoint}" \
    --install-disk "" \
    --talos-version "${talosVersion}" \
    ${patchFlags} \
    ${controlPatchFlags} \
    ${workerPatchFlags} \
    $SECRETS_FLAG \
    $OUTPUT_FLAG

  if [ $# -eq 2 ]; then
    chmod 644 $2/controlplane.yaml $2/worker.yaml $2/talosconfig
    echo "✅ Configuration generated in \"$2\""
  fi
''
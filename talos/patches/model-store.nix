#
# Defines a PVC for the models that we use in vllm.
#
{
  pkgs,
  kubelib ? null, 
  name,
  server,
  path,
}:
let
  size = "500Gi";

  modelStoreManifests = ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: ${name}-pv
    spec:
      capacity:
        storage: ${size}
      volumeMode: Filesystem
      accessModes:
        - ReadOnlyMany          # Safe for vLLM scaling
      persistentVolumeReclaimPolicy: Retain
      storageClassName: manual-models
      mountOptions:
        - nfsvers=4.1
        - noatime               # Improves read performance
        - nolock
        - tcp
      nfs:
        server: ${server}
        path: ${path}
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: ${name}-pvc
      namespace: default
    spec:
      accessModes:
        - ReadOnlyMany
      storageClassName: manual-models
      resources:
        requests:
          storage: ${size}
      volumeName: ${name}-pv
  '';

in
# This writes the string directly to the output file without any extra formatting/indentation
pkgs.runCommand "model-store.yaml" {} ''
    set -euo pipefail
    
    (
      cat << 'PATCH_START'
cluster:
  inlineManifests:
    - name: model-store
      contents: |
        ---
PATCH_START
      echo "${modelStoreManifests}" | sed 's/^/        /'
      
    ) > "$out"
''
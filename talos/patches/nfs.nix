{
  pkgs,
  kubelib,
  server,
  path,
}:
let
  # Configuration for the NFS Provisioner
  nfsProvisionerValues = {
    nfs = {
      server = server;
      path = path;
      mountOptions = [
        "nfsvers=4.1" # FORCE NFSv4
        "noatime"
        "nolock"
        "tcp"
      ];
    };

    storageClass = {
      name = "nfs-client";
      defaultClass = false;
      reclaimPolicy = "Retain";
    };
  };

  # Download the Chart
  nfs_chart = kubelib.downloadHelmChart {
    repo = "https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/";
    chart = "nfs-subdir-external-provisioner";
    version = "4.0.18";
    chartHash = "sha256-STkDh6TzNnouJvHYmwmm42dSN7vDfguxhOz01aOa3Dc=";
  };

  # Render the Chart
  renderedNfsManifests = kubelib.buildHelmChart {
    name = "nfs-provisioner";
    chart = nfs_chart;
    namespace = "kube-system";
    values = nfsProvisionerValues;
  };

in
pkgs.runCommand "nfs-provisioner.yaml" { } ''
      set -euo pipefail
      
      (
        cat << 'PATCH_START'
  cluster:
    inlineManifests:
      - name: nfs-provisioner
        contents: |
  PATCH_START
        sed 's/^/        /' "${renderedNfsManifests}"
        
      ) > "$out"
''

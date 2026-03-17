{
  pkgs,
  kubelib,
}:
let
  # --- Configuration ---
  devicePluginValues = {
    # If using Talos or a custom path, you might need to adjust these
    # but defaults usually work for standard setups.
    gfd = {
      enabled = true; # GPU Feature Discovery (labels nodes with GPU model/memory)
    };
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key = "node-role.kubernetes.io/control-plane";
                  operator = "DoesNotExist";
                }
              ];
            }
          ];
        };
      };
    };
  };

  # Download the NVIDIA Device Plugin Chart
  nvidia_chart = kubelib.downloadHelmChart {
    repo = "https://nvidia.github.io/k8s-device-plugin";
    chart = "nvidia-device-plugin";
    version = "v0.18.0"; 
    chartHash = "sha256-B8kLxp/UvWZKUw8kRoLjSuDgvL+9IHyssJi+H3wnjHY="; # Run once to get hash
  };

  # Render the Chart
  renderedNvidiaManifests = kubelib.buildHelmChart {
    name = "nvidia-device-plugin";
    chart = nvidia_chart;
    namespace = "kube-system";
    values = devicePluginValues;
  };

in
pkgs.runCommand "nvidia-plugin.yaml" {} ''
    set -euo pipefail
    
    (
      cat << 'PATCH_START'
cluster:
  inlineManifests:
    - name: nvidia-device-plugin
      contents: |
PATCH_START
    
      sed 's/^/        /' "${renderedNvidiaManifests}"
      
    ) > "$out"
''
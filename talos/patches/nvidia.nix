{
  pkgs,
  kubelib,
}:
let
  # ── Kernel modules patch (per-machine, conditional) ───────────
  kernelModulesPatch = pkgs.writeText "nvidia-kernel-modules.yaml" ''
    machine:
      kernel:
        modules:
          - name: nvidia
          - name: nvidia_uvm
          - name: nvidia_drm
          - name: nvidia_modeset
      sysctls:
        net.core.bpf_jit_harden: 1
  '';

  runtimeClassManifest = pkgs.writeText "nvidia-runtime-class.yaml" ''
    apiVersion: node.k8s.io/v1
    kind: RuntimeClass
    metadata:
      name: nvidia
    handler: nvidia
  '';

  runtimeClassPatch = pkgs.runCommand "nvidia-runtime-class-patch.yaml" { } ''
    set -euo pipefail
    (
      cat << 'PATCH_START'
    cluster:
      inlineManifests:
        - name: nvidia-runtime-class
          contents: |
    PATCH_START
      sed 's/^/        /' "${runtimeClassManifest}"
    ) > "$out"
  '';

  # ── Device plugin helm chart (cluster-wide) ───────────────────
  devicePluginValues = {
    gfd = {
      enabled = true;
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

  nvidia_chart = kubelib.downloadHelmChart {
    repo = "https://nvidia.github.io/k8s-device-plugin";
    chart = "nvidia-device-plugin";
    version = "v0.18.0";
    chartHash = "sha256-B8kLxp/UvWZKUw8kRoLjSuDgvL+9IHyssJi+H3wnjHY=";
  };

  renderedNvidiaManifests = kubelib.buildHelmChart {
    name = "nvidia-device-plugin";
    chart = nvidia_chart;
    namespace = "kube-system";
    values = devicePluginValues;
  };

  helmPatch = pkgs.runCommand "nvidia-plugin.yaml" { } ''
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
  '';

in
{
  # Cluster-wide: the device plugin inline manifest
  inherit helmPatch runtimeClassPatch;

  # Per-machine: kernel modules, only applied when machine.nvidia = true
  inherit kernelModulesPatch;
}

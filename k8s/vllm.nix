{
  pkgs,
  lib,
  cfg,
}:

let
  models = cfg.models or { };

  renderModel =
    name: m:
    let
      model = m.model;
      servedModelName = m.servedModelName or name;
      port = m.port or 8000;
      replicas = m.replicas or 1;
      modelsDir = m.modelsDir or "/var/models";
      image = m.image or "vllm/vllm-openai:v0.18.0-cu130";
      extraArgs = m.extraArgs or [ ];
      defaultResources = {
        requests = {
          cpu = "4";
          memory = "16Gi";
          "nvidia.com/gpu" = "1";
        };
        limits = {
          cpu = "8";
          memory = "32Gi";
          "nvidia.com/gpu" = "1";
        };
      };
      resources = lib.recursiveUpdate defaultResources (m.resources or { });
    in
    ''
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: vllm-${name}
        namespace: workshop
        labels:
          app: vllm-${name}
      spec:
        replicas: ${toString replicas}
        strategy:
          type: Recreate
        selector:
          matchLabels:
            app: vllm-${name}
        template:
          metadata:
            labels:
              app: vllm-${name}
          spec:
            runtimeClassName: nvidia
            tolerations:
              - key: "nvidia.com/gpu"
                operator: "Exists"
            containers:
              - name: vllm
                image: ${image}
                command:
                  - "vllm"
                  - "serve"
                  - "${modelsDir}/${model}"
                  - "--served-model-name"
                  - "${servedModelName}"
                  - "--port"
                  - "${toString port}"${lib.concatMapStrings (arg: "\n            - \"${arg}\"") extraArgs}
                ports:
                  - name: http
                    containerPort: ${toString port}
                    protocol: TCP
                resources:
                  requests:
                    cpu: "${resources.requests.cpu}"
                    memory: "${resources.requests.memory}"
                    nvidia.com/gpu: "${resources.requests."nvidia.com/gpu"}"
                  limits:
                    cpu: "${resources.limits.cpu}"
                    memory: "${resources.limits.memory}"
                    nvidia.com/gpu: "${resources.limits."nvidia.com/gpu"}"
                volumeMounts:
                  - name: models-volume
                    mountPath: ${modelsDir}
                    readOnly: true
            volumes:
              - name: models-volume
                hostPath:
                  path: ${modelsDir}
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: vllm-${name}
        namespace: workshop
        labels:
          app: vllm-${name}
      spec:
        ports:
          - name: http
            port: 8000
            targetPort: ${toString port}
            protocol: TCP
        selector:
          app: vllm-${name}
    '';

  manifest =
    if models == { } then
      "# No models configured\n"
    else
      lib.concatStringsSep "\n---\n" (lib.mapAttrsToList renderModel models);
in
pkgs.writeText "vllm.yaml" manifest

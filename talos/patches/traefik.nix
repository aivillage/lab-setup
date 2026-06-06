{ pkgs, kubelib, ... }:

let
  traefik_chart = kubelib.downloadHelmChart {
    repo = "https://helm.traefik.io/traefik";
    chart = "traefik";
    version = "27.0.2";
    chartHash = "sha256-M5XZ6PY1XARrbxgGchBfeBvPzp9Rq2rD6tNOGAP0y9U=";
  };

  traefikValues = {
    deployment.kind = "DaemonSet";

    updateStrategy = {
      type = "RollingUpdate";
      rollingUpdate = {
        maxUnavailable = 2;
        maxSurge = 0;
      };
    };

    hostNetwork = true;
    dnsPolicy = "ClusterFirstWithHostNet";

    tolerations = [
      {
        key = "node-role.kubernetes.io/control-plane";
        operator = "Exists";
        effect = "NoSchedule";
      }
    ];

    additionalArguments = [
      "--api.insecure=true"
      "--log.level=INFO"
    ];

    ports = {
      web = {
        port = 80;
        exposedPort = 80;
      };
      websecure = {
        port = 443;
        exposedPort = 443;
      };
    };

    service = {
      type = "ClusterIP";
    };
  };

  traefikManifests = kubelib.buildHelmChart {
    name = "traefik";
    namespace = "kube-system";
    chart = traefik_chart;
    values = traefikValues;
  };

  dashboardRouteFile = pkgs.writeText "dashboard-route.yaml" ''
    ---
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      # Changed name slightly to avoid clashing with the Helm chart's internal route
      name: traefik-dashboard-web
      namespace: kube-system
    spec:
      entryPoints:
        - web
      routes:
        - match: Host(`localhost`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
          kind: Rule
          services:
            - name: api@internal
              kind: TraefikService
  '';

in
pkgs.runCommand "talos-traefik-patch.yaml" { } ''
  # Output the raw rendered Helm chart manifests
  cat ${traefikManifests} > $out

  # 2. NEW: Use 'cat' instead of 'echo' to safely append the file, protecting the backticks!
  cat ${dashboardRouteFile} >> $out
''

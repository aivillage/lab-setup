# i know this ingress is not needed but using for testing
{ lib }:

{
  mkPatchTraefik =
    {
      pkgs,
      kubelib,
      version ? "27.0.2",
      chartHash ? "sha256-M5XZ6PY1XARrbxgGchBfeBvPzp9Rq2rD6tNOGAP0y9U=",
      namespace ? "kube-system",
      dashboardHost ? "localhost",
      extraValues ? { },
    }:
    let
      traefik_chart = kubelib.downloadHelmChart {
        repo = "https://helm.traefik.io/traefik";
        chart = "traefik";
        inherit version chartHash;
      };

      defaultValues = {
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

      traefikValues = lib.recursiveUpdate defaultValues extraValues;

      traefikManifests = kubelib.buildHelmChart {
        name = "traefik";
        chart = traefik_chart;
        inherit namespace;
        values = traefikValues;
      };

      dashboardRouteFile = pkgs.writeText "dashboard-route.yaml" ''
        ---
        apiVersion: traefik.io/v1alpha1
        kind: IngressRoute
        metadata:
          name: traefik-dashboard-web
          namespace: ${namespace}
        spec:
          entryPoints:
            - web
          routes:
            - match: Host(`${dashboardHost}`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
              kind: Rule
              services:
                - name: api@internal
                  kind: TraefikService
      '';
    in
    pkgs.runCommand "talos-traefik-patch.yaml" { } ''
      cat ${traefikManifests} > $out
      cat ${dashboardRouteFile} >> $out
    '';
}

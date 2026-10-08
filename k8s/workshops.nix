{
  pkgs,
  lib,
  workshops ? [ ],
}:
let
  servicesOnly = lib.filter (w: w ? service && w.service != null) workshops;

  renderServiceManifest = w:
    let
      svc = w.service;
      actualName = if w.name == "yolo-l2" then "yolo-l2-verification" else "${w.name}-service";
      port = svc.port or 5000;
      envList = if svc ? env then svc.env else { };
      envYaml = if envList != { } then
        "\n          env:" + (lib.concatStrings (lib.mapAttrsToList (k: v: "\n            - name: ${k}\n              value: \"${toString v}\"") envList))
      else "";
    in
    ''
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ${actualName}
        namespace: workshop
        labels:
          app: ${actualName}
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: ${actualName}
        template:
          metadata:
            labels:
              app: ${actualName}
          spec:
            containers:
              - name: service
                image: ${svc.image}
                ports:
                  - containerPort: ${toString port}${envYaml}
                resources:
                  requests:
                    cpu: "100m"
                    memory: "128Mi"
                  limits:
                    cpu: "500m"
                    memory: "512Mi"
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: ${actualName}
        namespace: workshop
        labels:
          app: ${actualName}
      spec:
        selector:
          app: ${actualName}
        ports:
          - protocol: TCP
            port: ${toString port}
            targetPort: ${toString port}
    '';

  manifest = lib.concatStringsSep "\n---\n" (map renderServiceManifest servicesOnly);
in
pkgs.writeText "workshops.yaml" manifest

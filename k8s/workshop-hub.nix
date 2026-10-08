{
  pkgs,
  lib,
  cfg,
  lab ? { },
  machines ? { },
}:

let
  vip = cfg.vip or (throw "[workshop-hub.nix] cfg.vip must be specified");
  baseDomain = cfg.baseDomain or (throw "[workshop-hub.nix] cfg.baseDomain must be specified");
  hubImage = cfg.hub.image or "ghcr.io/aivillage/workshop-hub:0.1.0-904c993";
  sidecarImage = cfg.hub.sidecar.image or "ghcr.io/aivillage/workshop-sidecar:0.1.0-904c993";
  quotas = cfg.quotas or { };
  maxPods = toString (quotas.maxPods or 50);
  maxMemory = quotas.maxMemory or "128Gi";
  maxCpu = toString (quotas.maxCpu or "64");
  maxCpuLimit = toString (quotas.maxCpuLimit or "128");
  maxMemoryLimit = quotas.maxMemoryLimit or (quotas.maxMemory or "128Gi");

  privateSubnet = lab.subnets.private or (throw "[workshop-hub.nix] lab.subnets.private must be declared in lab.nix");
  publicSubnet = lab.subnets.public or (throw "[workshop-hub.nix] lab.subnets.public must be declared in lab.nix");

  findPublicIfaces =
    let
      candidateIfaces = lib.concatMap (
        m:
        let
          mCfg = m.machine or m;
          ifaces = mCfg.network-interfaces or { };
        in
        lib.mapAttrsToList (ifName: _ifVal: ifName) (
          lib.filterAttrs (_: ifVal: (ifVal.role or "") == "public") ifaces
        )
      ) (lib.attrValues machines);
    in
    if candidateIfaces != [ ] then
      lib.unique candidateIfaces
    else
      throw "[workshop-hub.nix] No network interface with role = 'public' found in machines.nix, and cfg.interface was not specified";

  resolvedPublicIfaces =
    if (cfg.interface or "") != "" then
      [ cfg.interface ]
    else
      findPublicIfaces;

  allExtraIngressPorts = lib.unique (
    lib.concatMap (w: w.extraIngressPorts or [ ]) (cfg.resolvedWorkshops or [ ])
  );

  renderWorkshop = w:
    let
      envYaml =
        if (w ? env && w.env != { }) then
          "\n    env:" + (lib.concatStrings (lib.mapAttrsToList (k: v: "\n      ${k}: \"${toString v}\"") w.env))
        else "";
      launchUriYaml =
        if (w ? launchUri && w.launchUri != null && w.launchUri != "") then
          "\n    launch_uri: \"${w.launchUri}\""
        else "";
    in
    "\n  - name: \"${w.name}\""
    + "\n    image: \"${w.image}\""
    + "\n    description: \"${w.description or w.name}\""
    + "\n    port: ${toString (w.port or 5000)}"
    + launchUriYaml
    + envYaml;

  renderedWorkshops =
    if (cfg ? resolvedWorkshops && cfg.resolvedWorkshops != [ ]) then
      "\nworkshops:" + (lib.concatStrings (map renderWorkshop cfg.resolvedWorkshops))
    else "";

  workshopHubConfigYaml = ''
    base_domain: "${baseDomain}"
    sidecar_image: "${sidecarImage}"
    workshop_namespace: "workshop"
    workshop_ttl_seconds: ${toString (cfg.workshopTtlSeconds or 7200)}
    workshop_idle_seconds: ${toString (cfg.workshopIdleSeconds or 1200)}
    garbage_collection_seconds: ${toString (cfg.garbageCollectionSeconds or 120)}
    sidecar_proxy_port: 8888
    sidecar_health_port: 9000
    workshop_pod_limit: ${maxPods}
    workshop_cpu_request: "${cfg.workshopCpuRequest or "100m"}"
    workshop_cpu_limit: "${cfg.workshopCpuLimit or "1000m"}"
    workshop_mem_request: "${cfg.workshopMemRequest or "256Mi"}"
    workshop_mem_limit: "${cfg.workshopMemLimit or "2Gi"}"${renderedWorkshops}
  '';

  manifest = ''
    # =============================================================================
    # 1. Namespaces
    # =============================================================================
    apiVersion: v1
    kind: Namespace
    metadata:
      name: workshop-hub-system
      labels:
        name: workshop-hub-system
        purpose: workshop-hub-control-plane
    ---
    apiVersion: v1
    kind: Namespace
    metadata:
      name: workshop
      labels:
        name: workshop
        purpose: workshop-pods
        managed-by: workshop-hub
        pod-security.kubernetes.io/enforce: privileged
    ---
    # =============================================================================
    # 2. RBAC
    # =============================================================================
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: workshop-hub-controller
      namespace: workshop-hub-system
      labels:
        app: workshop-hub
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: workshop-hub-controller
      labels:
        app: workshop-hub
    rules:
      - apiGroups: [""]
        resources: ["pods", "pods/status", "services"]
        verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
      - apiGroups: [""]
        resources: ["secrets"]
        verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
      - apiGroups: [""]
        resources: ["namespaces"]
        verbs: ["get"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: workshop-hub-manage-workshops
      namespace: workshop
      labels:
        app: workshop-hub
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: workshop-hub-controller
    subjects:
      - kind: ServiceAccount
        name: workshop-hub-controller
        namespace: workshop-hub-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: workshop-hub-self
      namespace: workshop-hub-system
      labels:
        app: workshop-hub
    rules:
      - apiGroups: [""]
        resources: ["configmaps"]
        verbs: ["get", "list", "watch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: workshop-hub-self-binding
      namespace: workshop-hub-system
      labels:
        app: workshop-hub
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: workshop-hub-self
    subjects:
      - kind: ServiceAccount
        name: workshop-hub-controller
        namespace: workshop-hub-system
    ---
    # =============================================================================
    # 3. Cilium L2 VIP & Announcements
    # =============================================================================
    apiVersion: cilium.io/v2
    kind: CiliumLoadBalancerIPPool
    metadata:
      name: workshop-lb-pool
    spec:
      blocks:
        - cidr: "${vip}/32"
    ---
    apiVersion: cilium.io/v2alpha1
    kind: CiliumL2AnnouncementPolicy
    metadata:
      name: workshop-l2-policy
    spec:
      nodeSelector:
        matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
      externalIPs: true
      loadBalancerIPs: true
      interfaces:
        ${lib.concatStringsSep "\n        " (map (iface: "- \"^${iface}\"") resolvedPublicIfaces)}
    ---
    # =============================================================================
    # 4. ConfigMap
    # =============================================================================
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: workshop-hub-config
      namespace: workshop-hub-system
    data:
      config.yaml: |
    ${lib.concatStrings (map (line: "    " + line + "\n") (lib.splitString "\n" (lib.trim workshopHubConfigYaml)))}
    ---
    # =============================================================================
    # 5. Deployment & Service
    # =============================================================================
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: workshop-hub
      namespace: workshop-hub-system
      labels:
        app: workshop-hub
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: workshop-hub
      template:
        metadata:
          labels:
            app: workshop-hub
        spec:
          serviceAccountName: workshop-hub-controller
          containers:
            - name: workshop-hub
              image: "${hubImage}"
              ports:
                - name: http
                  containerPort: 8080
                  protocol: TCP
              resources:
                requests:
                  cpu: "250m"
                  memory: "256Mi"
                limits:
                  cpu: "1000m"
                  memory: "1Gi"
              env:
                - name: BASE_DOMAIN
                  value: "${baseDomain}"
                - name: SIDECAR_IMAGE
                  value: "${sidecarImage}"
                - name: WORKSHOP_CONFIG
                  value: "/etc/workshop/config.yaml"
                - name: RUST_LOG
                  value: "info,hub=debug"
              volumeMounts:
                - name: config-volume
                  mountPath: /etc/workshop/config.yaml
                  subPath: config.yaml
          volumes:
            - name: config-volume
              configMap:
                name: workshop-hub-config
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: workshop-hub
      namespace: workshop-hub-system
      labels:
        app: workshop-hub
    spec:
      type: LoadBalancer
      selector:
        app: workshop-hub
      ports:
        - name: http
          port: 80
          targetPort: 8080
          protocol: TCP
    ---
    # =============================================================================
    # 6. Cilium Network Policies
    # =============================================================================
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: allow-hub-to-workshops
      namespace: workshop
    spec:
      description: "Allow workshop pods to receive traffic from the hub"
      endpointSelector:
        matchExpressions:
          - key: app.kubernetes.io/managed-by
            operator: In
            values: ["workshop-hub"]
      ingress:
        - fromEndpoints:
            - matchLabels:
                io.kubernetes.pod.namespace: workshop-hub-system
                app: workshop-hub
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
                - port: "9000"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "9000"
                  protocol: TCP${lib.concatMapStrings (p: "
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: workshop
      toPorts:
        - ports:
            - port: \"${toString p}\"
              protocol: TCP") allExtraIngressPorts}
    ---
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: allow-hub-egress-to-workshops
      namespace: workshop-hub-system
    spec:
      description: "Allow workshop-hub to reach workshop pods for proxying and health checks"
      endpointSelector:
        matchLabels:
          app: workshop-hub
      egress:
        - toEndpoints:
            - matchLabels:
                io.kubernetes.pod.namespace: kube-system
                k8s-app: kube-dns
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                io.kubernetes.pod.namespace: workshop
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
                - port: "9000"
                  protocol: TCP
        - toEntities:
            - kube-apiserver
    ---
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: allow-workshops-egress
      namespace: workshop
    spec:
      description: "Allow workshop pods to reach DNS, internet, and internal services"
      endpointSelector: {}
      egress:
        - toEndpoints:
            - matchLabels:
                io.kubernetes.pod.namespace: kube-system
                k8s-app: kube-dns
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toCIDRSet:
            - cidr: "0.0.0.0/0"
              except:
                - "${privateSubnet}"
                - "${publicSubnet}"
        - toEndpoints:
            - matchLabels:
                io.kubernetes.pod.namespace: workshop
    ---
    # =============================================================================
    # 7. Resource Quota
    # =============================================================================
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: workshop-quota
      namespace: workshop
    spec:
      hard:
        pods: "${maxPods}"
        requests.cpu: "${maxCpu}"
        limits.cpu: "${maxCpuLimit}"
        requests.memory: "${maxMemory}"
        limits.memory: "${maxMemoryLimit}"
    ---
    # =============================================================================
    # 8. Limit Range
    # =============================================================================
    apiVersion: v1
    kind: LimitRange
    metadata:
      name: workshop-limits
      namespace: workshop
    spec:
      limits:
        - default:
            cpu: "${cfg.sidecarCpuLimit or "50m"}"
            memory: "128Mi"
          defaultRequest:
            cpu: "50m"
            memory: "64Mi"
          max:
            cpu: "50"
            memory: "200Gi"
          min:
            cpu: "10m"
            memory: "4Mi"
          type: Container
  '';
in
pkgs.writeText "workshop-hub.yaml" manifest

{
  pkgs,
  kubelib,
}:
let
  ciliumValues = {
    ipam = {
      mode = "kubernetes";
    };

    kubeProxyReplacement = true;

    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN"
          "KILL"
          "NET_ADMIN"
          "NET_RAW"
          "IPC_LOCK"
          "SYS_ADMIN"
          "SYS_RESOURCE"
          "DAC_OVERRIDE"
          "FOWNER"
          "SETGID"
          "SETUID"
        ];
        cleanCiliumState = [
          "NET_ADMIN"
          "SYS_ADMIN"
          "SYS_RESOURCE"
        ];
      };
    };

    cgroup = {
      autoMount.enabled = false;
      hostRoot = "/sys/fs/cgroup";
    };

    k8sServiceHost = "localhost";
    k8sServicePort = 7445;

    dnsproxy = {
      enabled = true;
    };

    hubble = {
      enabled = true;
      relay.enabled = true;
      ui.enabled = true;
    };

    localRedirectPolicy = true;

    l2Announcements = {
      enabled = true;
    };

    ingressController = {
      enabled = true;
      default = true;
      loadbalancerMode = "shared";
      service = {
        loadBalancerIP = "10.211.0.50";
      };
    };

    tunnelProtocol = "vxlan";

    cni = {
      chainingMode = "none";
      exclusive = true;
    };

    gatewayAPI = {
      enabled = true;
      enableAlpn = true;
      enableAppProtocol = true;
    };

    hostPort = {
      enabled = true;
    };

    nodePort = {
      enabled = true;
    };

    externalIPs = {
      enabled = true;
    };

    loadBalancer = {
      mode = "snat";
      serviceTopology = true;
    };
  };

  l2Resources = ''
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: cilium-l2-announcements
      namespace: kube-system
    rules:
      - apiGroups: ["coordination.k8s.io"]
        resources: ["leases"]
        verbs: ["get", "list", "watch", "create", "update", "patch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: cilium-l2-announcements
      namespace: kube-system
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: cilium-l2-announcements
    subjects:
      - kind: ServiceAccount
        name: cilium
        namespace: kube-system  
  '';

  cilium_chart = kubelib.downloadHelmChart {
    repo = "https://helm.cilium.io/";
    chart = "cilium";
    version = "v1.18.3";
    chartHash = "sha256-f+3s8+EmXiiqJ5p4dUtpQHWGTYflrO6L9Nj1zMMgh6w=";
  };

  renderedCiliumManifests = kubelib.buildHelmChart {
    name = "cilium";
    chart = cilium_chart;
    namespace = "kube-system";
    values = ciliumValues;
    includeCRDs = true;
  };

in
pkgs.runCommand "cilium.yaml" {} ''
    set -euo pipefail
    
    (
      cat << 'PATCH_START'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  inlineManifests:
    - name: cilium
      contents: |
PATCH_START
    
      sed 's/^/        /' "${renderedCiliumManifests}"

      cat << 'L2_START'
    - name: cilium-l2
      contents: |
L2_START

      echo "${l2Resources}" | sed 's/^/        /'
      
    ) > "$out"
''
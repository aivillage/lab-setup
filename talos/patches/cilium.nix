{ pkgs, kubelib, ... }:

let
  cilium_chart = kubelib.downloadHelmChart {
    repo = "https://helm.cilium.io/";
    chart = "cilium";
    version = "1.19.4";
    chartHash = "sha256-u4FPk5HpTGHUiRMObVrK7v9FaLQSXGNGsCZcqVZ27iw="; # Ensure this is your updated hash
  };

  ciliumValues = {
    ipam.mode = "kubernetes";
    kubeProxyReplacement = true;
    k8sServiceHost = "localhost";
    k8sServicePort = 7445;
    securityContext.capabilities.ciliumAgent = [
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
    securityContext.capabilities.cleanCiliumState = [
      "NET_ADMIN"
      "SYS_ADMIN"
      "SYS_RESOURCE"
    ];
    cgroup.autoMount.enabled = false;
    cgroup.hostRoot = "/sys/fs/cgroup";
  };

  ciliumManifests = kubelib.buildHelmChart {
    name = "cilium";
    namespace = "kube-system";
    chart = cilium_chart;
    values = ciliumValues;
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
        verbs: ["get", "list", "watch", "create", "update", "delete", "patch"]
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

in
pkgs.runCommand "talos-cilium-patch.yaml"
  {
    inherit l2Resources;
  }
  ''
    # 1. Output the raw rendered Helm chart manifests directly
    cat ${ciliumManifests} > $out

    # 2. Add a YAML document separator to ensure safe parsing
    echo -e "\n---\n" >> $out

    # 3. Append the raw L2 RBAC resources (no indentation needed)
    echo "$l2Resources" >> $out
  ''

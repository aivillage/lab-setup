# 🧩 Cluster À La Carte Modules & Local Overrides Guide

This document describes the **À La Carte Modular Plugin Architecture** for AI Village clusters (`lab1`, `lab2`, etc.).

---

## 📌 Architecture Overview

Clusters in AI Village separate configuration into two distinct layers:
1. **Talos OS Machine Modules (`talosModules`)**: Bare-metal operating system patches (kernel modules, Kubelet subnet restrictions, VIPs). Output to `.cluster/talos/base-patches/`.
2. **Kubernetes Addon Modules (`k8sModules`)**: Kubernetes manifests and Helm charts applied after Kubernetes is initialized. Output to `.cluster/k8s/addons/`.

This separation guarantees **zero regex string filtering**, **zero filename collision**, and **100% clean isolation** between operating system patches and Kubernetes manifests.

---

## 🛠️ Built-in Module Directory

| Module Name | Category | Trigger / Condition | Purpose |
| :--- | :--- | :--- | :--- |
| **`"cluster-base"`** | Talos OS | **Always Enabled** | Configures Control Plane VIP (`10.200.10.30`), Pod CIDR (`10.244.0.0/16`), and Service CIDR (`10.96.0.0/12`). |
| **`"kubelet-subnets"`**| Talos OS | **Always Enabled** | Restricts Kubelet `nodeIP` strictly to Cluster VLAN 10 (`10.200.10.0/24`). |
| **`"nvidia-gpu"`** | Talos OS | Auto-enabled when any node has `nvidia = true;` | Loads `nvidia`, `nvidia_uvm`, `nvidia_drm` kernel modules & configures containerd runtime. |
| **`"cilium"`** | K8s Addon | Enabled by default | Generates Cilium CNI Helm values & Talos inline HTTP loader manifest. |
| **`"apiserver-rbac"`**| K8s Addon | Enabled by default | Authorizes Kubelet API Server RBAC rules. |
| **`"nvidia-runtime"`**| K8s Addon | Auto-enabled when any node has `nvidia = true;` | Deploys NVIDIA GPU Operator Helm chart & Kubernetes `RuntimeClass`. |
| **`"nfs-storage"`** | K8s Addon | Enabled if `nfsServer` is configured | Creates NFS `StorageClass` & PersistentVolume definitions. |

---

## 💻 Example 1: Standard AI Cluster (`lab1/cluster.nix`)

In a standard cluster with GPU nodes, NVIDIA modules are automatically activated without extra configuration:

```nix
{
  name = "lab1";
  coordinator = "coordinator";
  controlVip = "10.200.10.30"; # Example VIP for VLAN 10 schema

  # Bare-Metal Operating System patches (supports built-in names AND local file paths!)
  talosModules = [
    "cluster-base"
    "kubelet-subnets"
    ./patches/lab1-custom-sysctls.yaml   # <--- Brand new Talos OS patch ONLY in lab1!
  ];

  # Kubernetes Addon modules (supports built-in names AND local file paths!)
  k8sModules = [
    "cilium"
    "apiserver-rbac"
    ./patches/lab1-metrics-server.yaml  # <--- Brand new K8s addon ONLY in lab1!
  ];
}
```

---

## ⚡ Example 2: Lightweight CPU-Only Workshop (`lab2/cluster.nix`)

For a CPU-only cluster, omit NVIDIA modules completely:

```nix
{
  name = "lab2";
  coordinator = "coordinator";
  controlVip = "10.200.10.30"; # Example VIP for VLAN 10 schema

  talosModules = [ "cluster-base" "kubelet-subnets" ];
  k8sModules   = [ "cilium" "apiserver-rbac" ];
}
```

---

## 🧪 Example 3: Overriding Built-in Modules Locally (`overrides`)

If you are developing inside `lab1` and need to test a custom or experimental patch without editing `labsetup` source code, use the **`overrides`** attribute in `cluster.nix`:

```nix
{
  name = "lab1";
  coordinator = "coordinator";
  controlVip = "10.200.10.30";

  # Local Module Overrides!
  overrides = {
    # Replace built-in nvidia-gpu OS patch with a local file in lab1:
    "nvidia-gpu"     = ./patches/custom-nvidia-kernel.yaml;

    # Replace built-in Cilium CNI with a local custom Helm values file:
    "cilium"         = ./patches/my-cilium-custom.nix;

    # Add a custom Kubernetes addon manifest:
    "custom-metrics" = ./patches/metrics-server.yaml;
  };
}
```

When `cluster gen talos` or `nixos-rebuild coordinator` runs:
1. `labsetup` checks `overrides."nvidia-gpu"`.
2. Because it's defined, `labsetup` ignores the built-in patch and uses `./patches/custom-nvidia-kernel.yaml`!

---

## 🚀 CLI Commands Reference

- **Render Talos OS Node Configs**: `nix develop --command cluster gen talos`
- **Render Kubernetes Addons**: `nix develop --command cluster gen k8s`
- **Apply Talos OS Config**: `nix develop --command cluster apply talos worker1`
- **Apply Kubernetes Addons**: `nix develop --command cluster apply k8s`
- **Deploy to Coordinator**: `nix develop --command nixos-rebuild coordinator`

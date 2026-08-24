# AI Village Lab Setup & Cluster Coordinator Infrastructure

This repository provides the core Coordinator engine, ProxyDHCP/TFTP/iPXE netbooting, Inspector guest discovery, Talos OS configuration compiler, and `cluster-cli` operational tools for the AI Village bare-metal Kubernetes cluster.

---

## 🛠️ Quick Command Reference

When working inside any lab directory (e.g. `lab1`) on `spark2` or via `nix develop` on your laptop, the unified **`cluster`** command is available:

| Command | Description |
| :--- | :--- |
| `cluster status` | Inspect live registered nodes, Control Plane ETCD health, Kubernetes workloads, and NVIDIA GPU vitals. |
| `cluster wakeup <all\|node>` | Wake up specific node(s) or the entire cluster via Wake-on-LAN (locally or tunneled through Coordinator). |
| `cluster shutdown <all\|node>` | Gracefully shut down node(s) or the entire cluster (Workers first, Control Plane last). |
| `cluster discover [-w]` | Fetch hardware discovery reports from Coordinator and auto-generate `machines.nix`. |
| `cluster pull-secrets` | Synchronize PKI secrets, `talosconfig`, and `kubeconfig` from Coordinator host to `.cluster/`. |
| `cluster gen <talos\|k8s>` | Render Talos OS machine configs or Day-2 Kubernetes manifests. |
| `cluster apply <talos\|k8s>` | Apply Talos node configurations or Kubernetes manifests to the cluster. |
| `nixos-rebuild spark2` | Rebuild and activate updated Coordinator host configuration on `spark2`. |

---

## 📡 Coordinator Service & Boot Modes

The Coordinator daemon (`coordinator.service` on port 8080) automatically routes booting nodes based on MAC address matching against `machines.nix`:

1. **Mode 1: Hardware Discovery** (`inspector-netboot`):
   - Served to unknown/uninspected MAC addresses.
   - Boots an ephemeral Linux RAMDisk that audits PCI devices, NICs, and NVMe disks, and POSTs reports to `http://<coordinator>:8080/api/reports`.
2. **Mode 2: Talos OS Kubernetes Boot**:
   - Served to known MAC addresses declared in `machines.nix`.
   - Streams Talos OS kernel (`vmlinuz`) and initrd over Nginx HTTP (`coordinator-netboot-server` on port 80).
3. **Mode 3: Storage Disk Wipe**:
   - Served when disk wiping is requested in `/var/lib/coordinator/wipe/wipe.json` or via `POST /api/wipe`.
   - Boots the Inspector wipe payload to zero-wipe disks, POSTs logs to `/api/wipelog`, and powers off the node.

---

## 📁 Key File Locations

- **`packages/coordinator/server.py`**: Multithreaded Python Coordinator daemon (Port 8080).
- **`packages/cluster-cli/cluster.py`**: Unified Python cluster CLI tool (`status`, `wakeup`, `shutdown`, `pull-secrets`).
- **`packages/inspector/`**: Rust hardware audit & wipe guest agent.
- **`/var/lib/coordinator/`**:
  - `inspector/`: Telemetry reports & dynamic `machines.nix`.
  - `talos/`: Rendered Talos OS configs, `talosconfig`, and `kubeconfig`.
  - `wipe/`: Node registration state (`wipe.json`) and audit logs.

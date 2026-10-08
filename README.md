# AI Village Lab Setup & Cluster Coordinator Infrastructure

This repository provides the core Coordinator engine, ProxyDHCP/TFTP/iPXE netbooting, Inspector guest discovery, Talos OS configuration compiler, and `cluster-cli` operational tools for the AI Village bare-metal Kubernetes cluster.

---

## Documentation Hub

Comprehensive architectural, authoring, and operational guides are maintained in `docs/`:

* [Operator Guide](docs/operator-guide.md): Practical on-site operational runbook, day-to-day workflows, attendee triage matrix, and failure recovery.
* [Workshop Architecture Reference](docs/workshop-architecture.md): Deep-dive into network and VIP architecture, Cilium L2 LoadBalancers, the 4-tier pod architecture, and session reaper mechanics.
* [Workshop Authoring Guide](docs/workshop-authoring.md): Challenge developer guide for authors covering `workshop.toml` schemas, dynamic CI container tagging, local builds, and model pre-seeding.
* [Cluster Modules Guide](docs/cluster-modules.md): Modular plugin architecture for bare-metal Talos OS patches and Kubernetes addons.

---

## Quick Command Reference

When working inside any lab directory (e.g. `lab1`) or via `nix develop` on your workstation, the unified **`cluster`** command is available:

| Command | Description |
| :--- | :--- |
| `cluster status` | Inspect live registered nodes, control plane etcd health, Kubernetes workloads, and NVIDIA GPU vitals. |
| `cluster wakeup [all\|<node>]` | Wake up specific node(s) or the entire cluster via Wake-on-LAN (locally or tunneled through Coordinator). |
| `cluster shutdown [all\|<node>]` | Gracefully shut down node(s) or the entire cluster (workers first, control plane last). |
| `cluster wipe` | Manage bare-metal storage disk wipe requests, inspect wipe states, and view audit logs. |
| `cluster discover [-w]` | Fetch hardware discovery reports from Coordinator and auto-generate `machines.nix`. |
| `cluster pull-secrets` | Synchronize PKI secrets, `talosconfig`, and `kubeconfig` from Coordinator host to `.cluster/`. |
| `cluster gen <talos\|k8s\|secrets>` | Render Talos OS machine configs, Day-2 Kubernetes manifests, or cluster PKI secrets. |
| `cluster apply <talos\|k8s>` | Apply Talos node configurations or Kubernetes manifests to the cluster. |
| `cluster bootstrap` | Bootstrap etcd cluster on the control plane and initialize Kubernetes administrative credentials. |
| `cluster show <machines\|configs\|reports\|network>` | Inspect machines, rendered configs, hardware discovery reports, or network architecture. |
| `cluster purge` | Purge all discovered hardware reports, wipe states, and local artifacts. |
| `nixos-rebuild coordinator [switch\|boot]` | Rebuild and activate (or stage for boot) the updated Coordinator host configuration. |

---

## Coordinator Service & Boot Modes

The Coordinator daemon (`coordinator.service` on port 8080) automatically routes booting nodes based on MAC address matching against `machines.nix`:

1. **Mode 1: Hardware Discovery** (`inspector-netboot`):
   - Served to unknown or uninspected MAC addresses.
   - Boots an ephemeral Linux RAMDisk that audits PCI devices, NICs, and NVMe disks, and POSTs reports to `http://<coordinator>:8080/api/reports`.
2. **Mode 2: Talos OS Kubernetes Boot**:
   - Served to known MAC addresses declared in `machines.nix`.
   - Streams Talos OS kernel (`vmlinuz`) and initrd over Nginx HTTP (`coordinator-netboot-server` on port 80).
3. **Mode 3: Storage Disk Wipe**:
   - Served when disk wiping is requested in `/var/lib/coordinator/wipe/wipe.json` or via `POST /api/wipe`.
   - Boots the Inspector wipe payload to zero-wipe disks, POSTs logs to `/api/wipelog`, and powers off the node.

---

## Key File Locations

- **`packages/coordinator/src/coordinator/main.py`**: Multithreaded FastAPI Coordinator daemon (Port 8080).
- **`packages/cluster-cli/src/cluster_cli/cli.py`**: Unified Python cluster CLI tool (`status`, `wakeup`, `shutdown`, `gen`, `apply`, etc.).
- **`crates/inspector/`**: Rust hardware audit & disk wipe guest agent.
- **`/var/lib/coordinator/`**:
  - `inspector/`: Telemetry reports and dynamic `machines.nix`.
  - `talos/`: Rendered Talos OS configs, `talosconfig`, and `kubeconfig`.
  - `wipe/`: Node registration state (`wipe.json`) and audit logs.

# AI Village Cluster - On-Site Operator Runbook & Triage Guide

This runbook serves as the practical operational manual and live triage guide for village proctors and on-site cluster operators managing AI Village bare-metal Kubernetes infrastructure.

---

## 1. Cluster Operational Workflows & Tooling

All cluster operations are executed from within the repository development shell. Entering the devshell provisions the environment with the unified `cluster` CLI, pre-authenticated `talosctl`, `kubectl`, `helm`, and NixOS deployment tooling.

```bash
# Enter the cluster management environment
nix develop
```

### Day-to-Day Lifecycle Commands

Daily power sequencing, health checks, and capacity audits are performed using the `cluster` CLI:

* `cluster status`: Displays real-time status of all registered bare-metal nodes, Kubernetes node readiness, control plane etcd health, active workload counts, and NVIDIA GPU vitals.
* `cluster wakeup [all|<node>]`: Broadcasts Wake-on-LAN packets across the private management network (locally or tunneled through the Coordinator) to power on nodes at the start of an event day.
* `cluster shutdown [all|<node>]`: Gracefully drains workloads and executes ACPI power-off across bare-metal nodes (worker nodes first, control plane last) at the close of an event.

### Manifest Compilation & Deployment

Kubernetes manifests and Talos OS machine configurations are fully declarative:

* `cluster gen k8s`: Compiles declarative Kubernetes manifests (CoreDNS, Cilium CNI, NVIDIA device plugin, local storage, Workshop Hub, and challenge workloads) into `.cluster/k8s/`.
* `cluster apply k8s`: Applies the compiled Kubernetes manifests to the active cluster.
* `cluster gen talos`: Generates Talos OS machine configuration patches for control plane and worker nodes into `.cluster/talos/`.
* `cluster apply talos`: Pushes rendered Talos machine configurations to live nodes via the Talos API.

### Coordinator Host Rebuilds

The coordinator host runs NixOS and provides ProxyDHCP, iPXE netbooting, hardware discovery ingestion, and local container/model registries. When updating coordinator configurations or network services, deploy changes using:

```bash
# Rebuild and activate configuration on the coordinator host
nixos-rebuild coordinator switch

# Alternative: target the host explicitly by hostname if required
nixos-rebuild spark2 switch
```

To stage configuration changes for the next system reboot without switching immediately, use `nixos-rebuild coordinator boot`.

### Read-Only Diagnostics for Attendee Support

During active workshop sessions, use read-only diagnostic commands to verify cluster health and support attendees without modifying cluster state:

```bash
# Check cluster-wide node status, internal IPs, and readiness
kubectl get nodes -o wide

# Check pod placement, health phase, and IP assignments in the workshop namespace
kubectl get pods -n workshop -o wide

# Inspect pod lifecycle events, pending conditions, and scheduling failures
kubectl describe pod <pod-name> -n workshop

# Inspect namespace resource usage against configured ceilings
kubectl describe resourcequota workshop-quota -n workshop

# Stream container logs from the attendee challenge container
kubectl logs -n workshop <pod-name> -c challenge-app --tail=100 -f

# Stream container logs from the proxy sidecar (routing decisions & activity timestamps)
kubectl logs -n workshop <pod-name> -c workshop-sidecar --tail=100 -f

# Monitor real-time bare-metal CPU and memory utilization across nodes
kubectl top nodes

# Monitor CPU and memory consumption of workshop pods
kubectl top pods -n workshop
```

---

## 2. Session Lifecycle, Quotas & Pod Cleanup

Workshop attendee environments are ephemeral and governed by automated garbage collection and resource quotas.

### Automated Session Reaper & Lifecycle Controls

The Tier 1 Workshop Hub controller runs an automated background garbage collector governed by `cluster.k8s.workshopHub.garbageCollectionSeconds` (default: `120` seconds).

The reaper operates under the following logic:
1. **Activity Tracking:** Each incoming HTTP request traversing the attendee pod's `workshop-sidecar` proxy updates an in-memory monotonic timestamp.
2. **Health Probing:** The Hub controller probes each active pod on its sidecar health port at `http://<pod-ip>:9000/health`. The sidecar returns JSON telemetry containing `last_activity_timestamp` and `idle_seconds`.
3. **80% Watermark Mercy Rule:** If total active pods in the `workshop` namespace remain below 80% of `cluster.k8s.workshopHub.quotas.maxPods`, the reaper exercises mercy and preserves idle pods to eliminate cold-start latency for returning attendees.
4. **Idle Eviction:** `cluster.k8s.workshopHub.workshopIdleSeconds` (default: `1200` seconds) dictates the inactivity ceiling. When namespace pod occupancy exceeds the 80% watermark, pods reporting `idle_seconds > cluster.k8s.workshopHub.workshopIdleSeconds` are pruned. Pods with unresponsive or failing sidecars are terminated immediately.
5. **Hard TTL Expiry:** `cluster.k8s.workshopHub.workshopTtlSeconds` (default: `7200` seconds / 2 hours) sets the absolute maximum lifetime for any pod. When a pod reaches this duration based on its `workshop-hub/ttl-expires-at` label, it is evicted unconditionally.

### Emergency Bulk Attendee Evacuation

When unexpected traffic surges saturate the namespace pod quota (configured via `cluster.k8s.workshopHub.quotas.maxPods`) or an unhandled exception causes multiple stale pods to persist, perform an emergency bulk evacuation:

```bash
# Bulk delete ALL ephemeral attendee pods while preserving shared services and vLLM
kubectl delete pods -n workshop -l app.kubernetes.io/managed-by=workshop-hub
```

> [!IMPORTANT]
> Shared backend challenge services (Tier 3) and the vLLM inference engine (Tier 4) do not carry the `app.kubernetes.io/managed-by=workshop-hub` label. Executing the bulk delete command above removes only ephemeral attendee pods and leaves shared infrastructure fully intact.

To delete a single stuck attendee pod with a grace period:

```bash
kubectl delete pod <pod-name> -n workshop --grace-period=15
```

### Hub Controller Restart

If the Hub controller's in-memory session cache desynchronizes from the live Kubernetes pod state, trigger a rolling restart of the controller deployment:

```bash
# Restart the Workshop Hub controller deployment
kubectl rollout restart deployment workshop-hub -n workshop-hub-system

# Verify rollout completion
kubectl rollout status deployment workshop-hub -n workshop-hub-system
```

---

## 3. Incident & Symptom Triage Matrix

Use this matrix to diagnose and remediate common on-site incidents during live workshops.

| Symptom | Probable Cause | Diagnostic Command | Remediation Action |
| :--- | :--- | :--- | :--- |
| **Hub Unreachable**<br>`Connection Refused` or timeout on `<cluster.k8s.workshopHub.vip>` (e.g. `10.200.20.31:80`). | 1. Worker node public interface down.<br>2. Hub deployment pod crashed or pending.<br>3. Cilium L2 announcement policy dropped or unassigned. | `kubectl get svc -n workshop-hub-system workshop-hub`<br>`kubectl get pods -n workshop-hub-system -o wide`<br>`kubectl logs -n kube-system -l k8s-app=cilium --tail=50` | 1. Verify Hub pod status is `Running`.<br>2. If pod crashed, run `kubectl rollout restart deployment workshop-hub -n workshop-hub-system`.<br>3. Verify physical link on worker interfaces matching `role = "public"` on `<lab.subnets.public>` (e.g. `10.200.20.0/24`). |
| **Session Cookie Desync**<br>Attendee experiences infinite redirects or HTTP 404. | Attendee browser retains a stale `workshop_session` cookie pointing to a pod that was pruned by the GC reaper. | `kubectl logs -n workshop-hub-system -l app=workshop-hub \| grep -i "user_id"`<br>`kubectl get pods -n workshop -l workshop-hub/user-id=<uuid>` | 1. Direct attendee to open an Incognito / Private browsing window or clear domain cookies for `<cluster.k8s.workshopHub.baseDomain>` (e.g. `lab.aivillage.local`).<br>2. If pod exists in an unhealthy state, delete it: `kubectl delete pod <pod-name> -n workshop`. |
| **Quota Exhaustion**<br>`exceeded quota: workshop-quota` errors logged by Hub. | Total pods in `workshop` reached `cluster.k8s.workshopHub.quotas.maxPods` due to rapid attendance surge or slow reap. | `kubectl describe resourcequota workshop-quota -n workshop`<br>`kubectl get pods -n workshop --field-selector=status.phase!=Running` | 1. Purge failed or terminated pods: `kubectl delete pods -n workshop --field-selector=status.phase=Failed`.<br>2. Bulk-evacuate stale attendee pods: `kubectl delete pods -n workshop -l app.kubernetes.io/managed-by=workshop-hub`. |
| **vLLM CUDA OOM / Timeouts**<br>HTTP 504 errors on `/v1/chat/completions` or prompt inference hangs. | 1. GPU VRAM Out-of-Memory (OOM).<br>2. KV cache exhaustion.<br>3. CUDA kernel lockup or driver Xid event. | `kubectl logs -n workshop -l app=vllm-gemma3 -c vllm --tail=100`<br>`talosctl -n <node-ip> dmesg \| grep -i -E "nv\|nvidia\|xid"` | 1. Check vLLM container logs for CUDA OOM exceptions.<br>2. Restart the inference deployment: `kubectl rollout restart deployment vllm-gemma3 -n workshop`.<br>3. If CUDA remains unresponsive, reboot the affected worker node via `talosctl -n <node-ip> reboot`. |
| **Stuck in ContainerCreating**<br>Attendee pod remains in `ContainerCreating` indefinitely. | 1. Local image pull lock or registry unreachable.<br>2. Node disk pressure / full rootfs.<br>3. Model directory volume mount failure. | `kubectl describe pod <pod-name> -n workshop` | 1. Inspect the `Events:` block of `kubectl describe pod`.<br>2. If image pull failed, verify coordinator registry on `<lab.coordinator.ip>` (e.g. `10.200.10.12:5000`) is accessible.<br>3. Delete the stuck pod to prompt the Hub controller to re-schedule on another node. |
| **Shared Backend Offline**<br>User container cannot connect to Tier 3 service (e.g. `email-indirect-service`). | Backend deployment failed, pod crashed, or internal CoreDNS resolution is degraded. | `kubectl get pods,svc -n workshop -l app=<service-name>`<br>`kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50` | 1. Verify backend pod is healthy and running.<br>2. Restart service: `kubectl rollout restart deployment <service-name> -n workshop`.<br>3. Check CoreDNS pod status and restart if DNS lookups stall: `kubectl rollout restart deployment coredns -n kube-system`. |

---

## 4. Failure Domains & System Recovery

### Worker Drop & Cilium L2 VIP Failover

The Workshop Hub external VIP `<cluster.k8s.workshopHub.vip>` (e.g. `10.200.20.31`) is managed by Cilium L2 Announcement Policies.
* The policy binds exclusively to physical network interfaces with `role = "public"` facing the attendee subnet `<lab.subnets.public>` (e.g. `10.200.20.0/24`), as declared in `machines.nix` (e.g. interface `enp88s0`).
* Control plane nodes are explicitly excluded (`node-role.kubernetes.io/control-plane: DoesNotExist`).
* If the worker node currently announcing the L2 VIP drops offline or loses its link on `<lab.subnets.public>`, Cilium elects another healthy worker node matching the policy to take over the VIP announcement within seconds.

**Triage and Verification:**
```bash
# Verify which node currently holds the L2 VIP announcement lease
kubectl describe ciliuml2announcementpolicy -n kube-system workshop-l2-policy

# Check node readiness across the cluster
kubectl get nodes -o wide

# Query Talos kernel logs on the affected worker over the private management network
talosctl -n <node-ip> dmesg

# If the node is powered off, trigger Wake-on-LAN
cluster wakeup <node-hostname>
```

### Control Plane / etcd Degradation

If Kubernetes API queries fail, `kubectl` hangs, or etcd heartbeats drop:
* **Triage:**
  * Query etcd service status directly against the control plane VIP `<cluster.vip.ip>` (e.g. `10.200.10.30`):
    ```bash
    talosctl -n 10.200.10.30 service etcd
    ```
  * Check etcd cluster member health and alarm states:
    ```bash
    talosctl -n 10.200.10.30 etcd members
    talosctl -n 10.200.10.30 etcd status
    ```
  * Query `kube-apiserver` status:
    ```bash
    talosctl -n 10.200.10.30 service kube-apiserver
    ```
* **Recovery:**
  * Restart the etcd service on the degraded control plane node:
    ```bash
    talosctl -n 10.200.10.30 service etcd restart
    ```
  * If the API server is stuck, restart it:
    ```bash
    talosctl -n 10.200.10.30 service kube-apiserver restart
    ```

### GPU / vLLM CUDA Hangs

Under heavy concurrent prompt generation, GPU memory exhaustion or driver-level stream lockups can cause vLLM inference to hang:
* **Triage:**
  * Tail the vLLM pod inference logs:
    ```bash
    kubectl logs -n workshop -l app=vllm-gemma3 -c vllm --tail=100 -f
    ```
  * Inspect GPU node kernel messages for NVIDIA driver errors or Xid fault codes:
    ```bash
    talosctl -n <gpu-node-ip> dmesg | grep -i -E "nv|nvidia|xid"
    ```
* **Recovery:**
  * Perform a rolling restart of the vLLM inference deployment:
    ```bash
    kubectl rollout restart deployment vllm-gemma3 -n workshop
    kubectl rollout status deployment vllm-gemma3 -n workshop
    ```
  * If the host GPU driver context is wedged, reboot the bare-metal worker node:
    ```bash
    talosctl -n <gpu-node-ip> reboot
    ```

### Network Partition Checks

The cluster relies on two isolated layer-2 network domains:
1. **Private Management Subnet (`<lab.subnets.private>`, e.g. `10.200.10.0/24`):**
   * Carries Talos API, Kubelet traffic, etcd consensus, netboot PXE/TFTP, and coordinator services.
   * If nodes lose control plane contact, test management reachability from the operator workstation:
     ```bash
     ping 10.200.10.12   # Coordinator (<lab.coordinator.ip>)
     ping 10.200.10.30   # Control Plane VIP (<cluster.vip.ip>)
     ```
   * Verify switch ports and VLAN 10 trunk links connecting bare-metal private interfaces.
2. **Public Workshop Subnet (`<lab.subnets.public>`, e.g. `10.200.20.0/24`):**
   * Carries attendee HTTP ingress to the Workshop Hub LoadBalancer VIP `<cluster.k8s.workshopHub.vip>` (e.g. `10.200.20.31`).
   * Test attendee VIP reachability from the workshop VLAN:
     ```bash
     curl -I http://10.200.20.31/
     ```
   * Ensure uplink ports connecting worker public NICs (`role = "public"`) to the attendee switch fabric are active and free of broadcast storms or spanning-tree blocking.

---

## 5. Architectural References & Related Documentation

For in-depth technical details on the underlying system design and instructions for packaging new challenges, refer to:

* [Workshop Architecture Reference](workshop-architecture.md): Deep-dive into network isolation, Cilium L2 LoadBalancers, the 4-tier pod architecture, and session reaper algorithms.
* [Workshop Authoring Guide](workshop-authoring.md): Step-by-step instructions for challenge developers on container packaging, `workshop.toml` schemas, CI tagging, and model pre-seeding.
* [Cluster Modules Guide](cluster-modules.md): Modular plugin architecture for bare-metal Talos OS patches and Kubernetes addons.

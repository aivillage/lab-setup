# AI Village Workshop Framework - System Architecture Reference

This reference document defines the technical architecture of the AI Village workshop framework, detailing network topology, VIP routing, Cilium L2 announcement mechanisms, the 4-tier pod architecture, and session lifecycle enforcement.

---

## 1. Network & VIP Architecture

The AI Village cluster establishes physical and logical segregation between administrative infrastructure and public attendee workshop environments.

```
                    +--------------------------------------------------+
                    |             Upstream Gateway Router              |
                    +--------------------------------------------------+
                                    |                  |
           VLAN 10: <lab.subnets.private>     VLAN 20: <lab.subnets.public>
           (e.g. 10.200.10.0/24)              (e.g. 10.200.20.0/24)
           Private Management Subnet          Public Attendee Subnet
                                    |                  |
          +-------------------------+                  +-------------------------+
          |                                                                      |
          v                                                                      v
+-----------------------------+                       +---------------------------------------+
| Control Plane VIP           |                       | Hub LoadBalancer VIP                  |
| <cluster.vip.ip>:6443       |                       | <cluster.k8s.workshopHub.vip>:80      |
| (e.g. 10.200.10.30:6443)    |                       | (e.g. 10.200.20.31:80)                |
+-----------------------------+                       +---------------------------------------+
| Coordinator Host Daemon     |                       | Cilium L2 Announcement                |
| <lab.coordinator.ip>:8080   |                       | Bound to worker NICs                  |
| (e.g. 10.200.10.12:8080)    |                       | matching role = "public"              |
+-----------------------------+                       +---------------------------------------+
          |                                                                      |
          +---------------------> [ Bare-Metal Nodes ] <-------------------------+
                                  Internal Pod Network:
                                  10.244.0.0/16 (Cilium CNI)
```

### Declarative Network Options & Subnet Mapping

The network architecture is configured in `lab.nix` using the following schema:

| Declarative Option | Example Value | Network Domain | Role & Operational Description |
| :--- | :--- | :--- | :--- |
| `lab.subnets.private` | `10.200.10.0/24` | VLAN 10 (Private) | Dedicated to BMC/IPMI, Talos machine API, Kubelet bindings, etcd consensus, iPXE netbooting, and internal registries. Isolated from attendee traffic. |
| `lab.subnets.public` | `10.200.20.0/24` | VLAN 20 (Public) | Dedicated to attendee Wi-Fi and Ethernet access. Attendee browsers connect strictly to ingress services on this subnet. |
| `cluster.vip.ip` | `10.200.10.30` | VLAN 10 (Private) | High-availability virtual IP for the Talos OS machine configuration API and Kubernetes API Server (TCP 6443). |
| `cluster.k8s.workshopHub.vip` | `10.200.20.31` | VLAN 20 (Public) | External LoadBalancer virtual IP announced by Cilium for HTTP ingress to the Workshop Hub (TCP 80). |
| `lab.coordinator.ip` | `10.200.10.12` | VLAN 10 (Private) | Static IP of the NixOS management station hosting the Coordinator daemon (TCP 8080), TFTP/iPXE boot server, and container registry. |
| `cluster.k8s.workshopHub.baseDomain` | `lab.aivillage.local` | VLAN 20 (Public) | Domain suffix used for attendee DNS resolution, session URL routing, and HTTP host-header dispatching. |

Attendee devices connect over VLAN 20 and can reach only `<cluster.k8s.workshopHub.vip>`. Network policies and physical routing prevent attendee traffic from traversing into `<lab.subnets.private>`.

---

## 2. Cilium L2 LoadBalancer Mechanism

Ingress into the workshop cluster does not use an external hardware load balancer. Instead, Cilium manages the external LoadBalancer IP `<cluster.k8s.workshopHub.vip>` directly across bare-metal worker nodes using Layer-2 Gratuitous ARP / Neighbor Discovery announcements.

### Dynamic Interface Detection in `k8s/workshop-hub.nix`

The Nix manifest compiler dynamically determines which physical network interfaces should announce the public VIP. Rather than hardcoding device names (such as `eth0` or `enp88s0`), `k8s/workshop-hub.nix` queries the cluster machine topology defined in `machines.nix`:

```nix
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
```

### Rendered Cilium L2 Resources

The compiler generates two core Cilium custom resources:

1. **`CiliumLoadBalancerIPPool`**: Allocates the specific `/32` VIP address from the public subnet pool:
   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumLoadBalancerIPPool
   metadata:
     name: workshop-lb-pool
   spec:
     blocks:
       - cidr: "10.200.20.31/32"
   ```

2. **`CiliumL2AnnouncementPolicy`**: Binds the VIP announcement lease to worker nodes and restricts egress announcements to public interfaces:
   ```yaml
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
       - "^enp88s0"
   ```

### High-Availability Failover

* **Control Plane Isolation:** Control plane nodes are excluded via `node-role.kubernetes.io/control-plane: DoesNotExist`, preventing attendee traffic from placing load on etcd or Kubernetes API nodes.
* **Lease Migration:** Cilium agents elect an active announcement leader among worker nodes with matching public interfaces. If the leader node crashes or its public NIC drops carrier link, Cilium expires the lease and re-elects an alternate worker node within 3 seconds, issuing Gratuitous ARP packets to update upstream switch CAM tables.

---

## 3. The 4-Tier Pod Architecture

The workshop runtime is structured into four distinct architectural tiers, separating public ingress, attendee isolation, shared challenge logic, and hardware-accelerated AI inference.

```
[ Attendee Browser ]
         |
         | HTTP Request (Host: lab.aivillage.local)
         v
+--------------------------------------------------------------------------------------------+
| TIER 1: Hub Controller (Namespace: workshop-hub-system)                                    |
|                                                                                            |
|  * Pingora Reverse Proxy (Port 8080 <- LoadBalancer:80)                                    |
|  * Session / Cookie Engine (workshop_session cookie)                                       |
|  * Dynamic Pod Controller (spawns Tier 2 pods via kube-rs)                                 |
|  * Background GC Reaper Loop (interval: cluster.k8s.workshopHub.garbageCollectionSeconds)  |
+--------------------------------------------------------------------------------------------+
         |
         | Reverse Proxy (Pod IP:8888)
         v
+--------------------------------------------------------------------------------------------+
| TIER 2: Ephemeral User Pods (Namespace: workshop)                                          |
|         Label: app.kubernetes.io/managed-by: workshop-hub                                  |
|                                                                                            |
|  +---------------------------------------+      +---------------------------------------+  |
|  | Container: workshop-sidecar           |      | Container: challenge-app              |  |
|  | - Port 8888: Reverse proxy to app     |      | - Ephemeral challenge environment     |  |
|  | - Port 9000: Axum GC activity server  |      | - e.g. Port 5000 / 8080 loopback      |  |
|  +---------------------------------------+      +---------------------------------------+  |
+--------------------------------------------------------------------------------------------+
         |                                                            |
         | TCP / HTTP internal                                        | OpenAI API internal
         v                                                            v
+------------------------------------+             +-----------------------------------------+
| TIER 3: Shared Challenge Services  |             | TIER 4: vLLM Inference Engine           |
|         (Namespace: workshop)      |             |         (Namespace: workshop)           |
|                                    |             |                                         |
|  * email-indirect-service:2525     |             |  * vllm-gemma3 Deployment (Replicas: 3) |
|  * rag-poisoning-service:5000      |             |  * runtimeClassName: nvidia             |
|  * yolo-l2-verification:5000       |             |  * hostPath: /var/models (read-only)    |
|                                    |             |  * Service: vllm-gemma3:8000            |
+------------------------------------+             +-----------------------------------------+
```

### Tier 1: Pingora-Based Workshop Hub Controller (`workshop-hub-system`)

* **Technology:** Custom Rust daemon built on Cloudflare Pingora and `kube-rs`.
* **Deployment:** Single-replica Deployment in `workshop-hub-system` exposed via `Service` of type `LoadBalancer` on port 80 (forwarding to container port 8080).
* **Session Management:**
  1. Inspects each incoming HTTP request for the `workshop_session` cookie. If not present, generates a cryptographically secure random session ID and returns a `Set-Cookie` header.
  2. Parses the request path to identify the target workshop from its catalog.
  3. Queries the Kubernetes API for a running pod in the `workshop` namespace labeled with:
     - `app.kubernetes.io/managed-by: workshop-hub`
     - `workshop-hub/user-id: <session-uuid>`
     - `workshop-hub/workshop-name: <workshop-name>`
  4. If no running pod exists, the Hub dynamically submits a Pod specification to the Kubernetes API, waiting for container readiness.
  5. Proxies the attendee's HTTP request directly to the pod's IP on port 8888.
  6. Executes a background garbage collector thread at the frequency defined by `cluster.k8s.workshopHub.garbageCollectionSeconds` (default: 120 seconds) to prune expired or idle pods.

### Tier 2: Ephemeral Attendee User Pods (`workshop`)

* **Lifespan:** Ephemeral, spawned on-demand when an attendee accesses a workshop URL.
* **Namespace:** `workshop`.
* **Labels:** `app.kubernetes.io/managed-by: workshop-hub`, `workshop-hub/user-id: <uuid>`, `workshop-hub/workshop-name: <name>`, `workshop-hub/ttl-expires-at: <epoch>`.
* **Dual-Container Architecture:**
  1. **`workshop-sidecar`**:
     * **Reverse Proxy (Port 8888):** Accepts traffic from the Tier 1 Hub controller and forwards it to the challenge container on localhost (e.g. `127.0.0.1:5000`). For each request forwarded, it updates an atomic in-memory monotonic timestamp.
     * **Activity Server (Port 9000):** Lightweight Axum HTTP service exposing `/health`. Returns JSON telemetry:
       ```json
       {
         "status": "ok",
         "idle_seconds": 42,
         "last_activity_timestamp": 1728320400
       }
       ```
  2. **`challenge-app`**:
     * Runs the user workspace, Jupyter notebook, or web application.
     * Injected with environment variables pointing to Tier 3 shared backends and Tier 4 vLLM endpoints.

### Tier 3: Shared Challenge Backend Services (`workshop`)

* **Lifespan:** Persistent background services running for the duration of the event.
* **Namespace:** `workshop`.
* **Deployment Pattern:** Static Kubernetes Deployments and Services rendered by `k8s/workshops.nix`.
* **Protection from GC:** These pods carry the label `app: <service-name>` and deliberately lack the `app.kubernetes.io/managed-by: workshop-hub` label. They are never touched by the Hub session reaper.
* **Standard Implementations:**
  * `email-indirect-service` (TCP 2525): Simulated corporate SMTP/IMAP backend.
  * `rag-poisoning-service` (TCP 5000): Vector store and document index service.
  * `yolo-l2-verification` (TCP 5000): Computer vision inference verification service.

### Tier 4: vLLM Inference Engine (`workshop`)

* **Role:** High-throughput, low-latency LLM inference server shared by all workshop challenges.
* **Deployment:** Multi-replica Deployment in the `workshop` namespace exposed via ClusterIP `vllm-gemma3:8000`.
* **Hardware Integration:**
  * Configured with `runtimeClassName: nvidia`.
  * Tolerates the GPU node taint `nvidia.com/gpu: Exists`.
  * Claims GPU capacity via resource requests: `nvidia.com/gpu: 1`.
* **Offline Model Weight Strategy:**
  * Uses `hostPath: /var/models` mounted read-only into `/var/models` in the container.
  * Launches vLLM pointing directly to the local filesystem path (e.g. `/var/models/google/gemma-3-4b-it`).
  * Pods never attempt to download model weights from HuggingFace over the public internet at runtime.

---

## 4. Session Lifecycle & Reaper Mechanics

To guarantee fair resource sharing on fixed bare-metal hardware, the Hub controller implements automated multi-stage session reclamation.

### Reaper Algorithm Flow

Every `cluster.k8s.workshopHub.garbageCollectionSeconds` (default: `120` seconds), the Hub background worker executes:

1. **Namespace Pod Audit:** Lists all pods in the `workshop` namespace carrying `app.kubernetes.io/managed-by: workshop-hub`.
2. **Sidecar Health Probing:** Queries `http://<pod-ip>:9000/health` for each pod:
   * If the probe times out or the sidecar reports a fatal condition, the pod is marked for immediate deletion.
   * If healthy, the reaper records the reported `idle_seconds`.
3. **80% Watermark Mercy Rule:**
   * Calculates current pod saturation: `utilization = current_pods / cluster.k8s.workshopHub.quotas.maxPods`.
   * **If `utilization < 0.80`:** The reaper enters **Mercy Mode**. Idle pods are preserved regardless of their `idle_seconds`, keeping attendee environments warm and responsive.
   * **If `utilization >= 0.80`:** Mercy Mode is disabled. Capacity reclamation begins.
4. **Idle Eviction (`cluster.k8s.workshopHub.workshopIdleSeconds`):**
   * Under capacity pressure (`utilization >= 0.80`), any pod with `idle_seconds > cluster.k8s.workshopHub.workshopIdleSeconds` (default: `1200` seconds) is deleted via the Kubernetes API.
5. **Hard TTL Expiry (`cluster.k8s.workshopHub.workshopTtlSeconds`):**
   * Enforces an absolute ceiling on pod lifetime.
   * At pod creation time, the Hub writes the label `workshop-hub/ttl-expires-at = <creation_time + cluster.k8s.workshopHub.workshopTtlSeconds>`.
   * If `current_time >= ttl-expires-at`, the pod is evicted unconditionally, even if an attendee is actively transmitting HTTP requests. This prevents abandoned tabs or background polling scripts from consuming resources indefinitely.

---

## 5. Declarative `lab.nix` Schema Reference

The Workshop Hub subsystem is configured in `lab.nix` under `cluster.k8s.workshopHub`:

```nix
cluster.k8s = {
  manifestTargets = [ "nvidia-device-plugin" ];

  workshopHub = {
    # Master switch for Workshop Hub controller, CRDs, and RBAC
    enable = true;

    # Public VIP assigned to CiliumLoadBalancerIPPool on <lab.subnets.public>
    vip = "10.200.20.31";

    # Base domain for attendee ingress and HTTP host headers
    baseDomain = "lab.aivillage.local";

    # Hard TTL lifetime ceiling for any attendee pod (seconds)
    workshopTtlSeconds = 7200;

    # Inactivity threshold before pod is eligible for eviction (seconds)
    workshopIdleSeconds = 1200;

    # Interval between Hub background garbage collection sweeps (seconds)
    garbageCollectionSeconds = 120;

    # List of active workshops to render into the Hub catalog
    workshops = [
      "llm-embeddings"
      "model-lab"
      "prompt-extraction"
      "rag-poisoning"
      "email-indirect"
    ];

    # Hub controller and proxy container images
    hub = {
      image = "ghcr.io/aivillage/workshop-hub:0.1.0-904c993";
      sidecar = {
        image = "ghcr.io/aivillage/workshop-sidecar:0.1.0-904c993";
      };
    };

    # Resource ceilings enforced on the workshop namespace
    quotas = {
      maxPods = 50;
      maxMemory = "128Gi";
      maxCpu = "64";
      maxCpuLimit = "128";
    };

    # Default resource requests and limits applied to individual attendee pods
    workshopCpuRequest = "100m";
    workshopCpuLimit = "1000m";
    workshopMemRequest = "256Mi";
    workshopMemLimit = "2Gi";
  };
};
```

### Parameter Reference Table

| Option Name | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `cluster.k8s.workshopHub.enable` | boolean | `false` | Enables manifest compilation for Workshop Hub controller, Cilium L2 pools, RBAC, and quotas. |
| `cluster.k8s.workshopHub.vip` | string | *required* | Static IPv4 address on `<lab.subnets.public>` allocated for attendee ingress. |
| `cluster.k8s.workshopHub.baseDomain` | string | *required* | Domain name routed to the VIP (e.g. `lab.aivillage.local`). |
| `cluster.k8s.workshopHub.workshopTtlSeconds` | integer | `7200` | Absolute maximum lifetime of an attendee pod before unconditional termination. |
| `cluster.k8s.workshopHub.workshopIdleSeconds` | integer | `1200` | Inactivity duration after which a pod is eligible for reclamation when above 80% capacity. |
| `cluster.k8s.workshopHub.garbageCollectionSeconds` | integer | `120` | Sweep frequency of the background session reaper thread. |
| `cluster.k8s.workshopHub.workshops` | list of strings | `[]` | Names of workshops from the workshops flake to include in the active catalog. |
| `cluster.k8s.workshopHub.hub.image` | string | *pinned OCI* | Container image for the Pingora-based Workshop Hub controller. |
| `cluster.k8s.workshopHub.hub.sidecar.image` | string | *pinned OCI* | Container image for the sidecar reverse proxy and health endpoint. |
| `cluster.k8s.workshopHub.quotas.maxPods` | integer | `50` | Maximum simultaneous pods permitted in the `workshop` namespace. |
| `cluster.k8s.workshopHub.quotas.maxMemory` | string | `"128Gi"` | Total aggregate memory requests allowed in the `workshop` namespace. |
| `cluster.k8s.workshopHub.quotas.maxCpu` | string | `"64"` | Total aggregate CPU requests allowed in the `workshop` namespace. |
| `cluster.k8s.workshopHub.quotas.maxCpuLimit` | string | `"128"` | Total aggregate CPU limits allowed in the `workshop` namespace. |
| `cluster.k8s.workshopHub.workshopCpuRequest` | string | `"100m"` | Default CPU request applied to individual attendee pods. |
| `cluster.k8s.workshopHub.workshopCpuLimit` | string | `"1000m"` | Default CPU limit applied to individual attendee pods. |
| `cluster.k8s.workshopHub.workshopMemRequest` | string | `"256Mi"` | Default memory request applied to individual attendee pods. |
| `cluster.k8s.workshopHub.workshopMemLimit` | string | `"2Gi"` | Default memory limit applied to individual attendee pods. |

---

## 6. Cross-References

* [Operator Guide](operator-guide.md): Practical triage matrix, pod evacuation commands, and failure recovery.
* [Workshop Authoring Guide](workshop-authoring.md): How to package, containerize, tag, and register new workshops.

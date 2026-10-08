# AI Village Workshop Authoring & Challenge Developer Guide

This guide describes how to author, package, containerize, and integrate new challenges into the AI Village workshop framework.

---

## 1. Overview of Workshop Packaging

Workshop challenges are maintained in the `workshops` repository. Each workshop is encapsulated in its own top-level directory (`workshops/<name>/`) and governed by a `workshop.toml` manifest.

```
workshops/
├── flake.nix
├── scripts/
│   └── build_container.sh
└── <name>/
    ├── workshop.toml
    ├── Dockerfile          # User container (Pattern A)
    ├── user/               # User container (Pattern B)
    │   └── Dockerfile
    └── service/            # Companion backend service (Pattern B)
        └── Dockerfile
```

### The Two-Tier Workshop Pattern

The framework supports two architectural patterns for challenge execution:

#### Pattern A: Standalone User Container (`[user]`)
* **Use Case:** Self-contained challenges, such as interactive Jupyter notebook environments, client-side reverse engineering, or isolated web exploitation tasks.
* **Architecture:** The Hub controller spawns an ephemeral pod containing the `workshop-sidecar` and the challenge container.
* **Connectivity:** The attendee connects through the Hub VIP directly to the user container. All challenge state is isolated to that attendee's pod.

#### Pattern B: Companion Backend Architecture (`[user]` + `[service]`)
* **Use Case:** Challenges requiring multi-actor dynamics, persistent shared databases, prompt exfiltration targets, or verification oracles (e.g. `email-indirect`, `rag-poisoning`, `yolo-l2`).
* **Architecture:**
  * **User Container (`[user]`):** Ephemeral attendee interface (e.g. an email client or attacker terminal) spawned on-demand in Tier 2.
  * **Service Container (`[service]`):** A persistent, shared Tier 3 deployment running in the `workshop` namespace.
* **Connectivity:** The user container communicates with the companion backend over internal Kubernetes DNS at `http://<service-name>:<port>`.

---

## 2. `workshop.toml` Schema Reference

Every workshop directory must contain a `workshop.toml` file at its root.

### Annotated Example (`workshops/email-indirect/workshop.toml`)

```toml
# Unique alphanumeric identifier for the challenge (matches directory name)
name = "email-indirect"

# Human-readable title and description displayed in the Hub landing catalog
description = "OmniCorp deployed an automated executive email assistant. Probe the agent and exfiltrate confidential corporate data."

# Optional: Hugging Face model identifier required for GPU inference
model = "google/gemma-3-4b-it"

# =============================================================================
# User Container Specification (Tier 2 - Ephemeral per Attendee)
# =============================================================================
[user]
# OCI image repository (OMIT image tags to enable dynamic Git SHA pinning)
image = "ghcr.io/aivillage/workshops/email-indirect-user"

# TCP port that the user challenge application listens on internally
port = 5000

# Optional: Additional TCP ports opened through Cilium network policies
extraIngressPorts = [25]

# Optional: Specific URL subpath to launch in the attendee's browser
# launchUri = "/lab/tree/challenge.ipynb"

# Environment variables injected into the attendee user container
[user.env]
CHALLENGE_SERVER_HOST = "email-indirect-service"
CHALLENGE_SERVER_PORT = 2525
MY_LISTEN_PORT = 25
WEB_PORT = 5000

# =============================================================================
# Companion Backend Service Specification (Tier 3 - Shared Persistent Service)
# Omit this entire block for standalone Pattern A challenges.
# =============================================================================
[service]
# OCI image repository for the backend service (OMIT image tags)
image = "ghcr.io/aivillage/workshops/email-indirect-service"

# TCP port exposed by the backend service in Kubernetes
port = 2525

# Environment variables injected into the shared backend service container
[service.env]
VLLM_URL = "http://vllm-gemma3:8000/v1/chat/completions"
VLLM_MODEL = "gemma-3"
```

---

## 3. Container Tagging & CI Integration

The framework enforces automated, reproducible image tagging across development, continuous integration, and cluster deployment.

### Image Tagging Modes in `workshop.toml`

Images in `workshop.toml` can either omit tags for automated CI/production resolution or specify explicit tags for development:

```toml
# Standard CI/Production: Omit tag for dynamic Git SHA resolution
image = "ghcr.io/aivillage/workshops/email-indirect-user"

# Supported: Explicit tag pinned for local development or fixed releases
# image = "ghcr.io/aivillage/workshops/email-indirect-user:dev-test"

# Prohibited: :latest is strictly rejected
# image = "ghcr.io/aivillage/workshops/email-indirect-user:latest"
```

* **Dynamic Git SHA Resolution (Standard):** Omitting image tags is standard for continuous integration and production deployments. The Nix manifest generator in `labsetup` (`talos/default.nix`) automatically appends the current Git commit hash from the `workshops` flake input:
  ```nix
  "${rawImage}:${gitRev}"
  ```
  If an image is untagged and the `workshops` flake input does not provide a git revision (`shortRev` or `dirtyShortRev`), Nix evaluation halts with an actionable error directing the developer to either commit changes or pin a tag.
* **Explicit Tag Pinning (Development & Pinned Releases):** Pinning tags directly in `workshop.toml` (e.g. `image = "ghcr.io/aivillage/workshops/email-indirect-user:dev-test"`) is fully supported for local development or pinned releases. When an explicit tag is present, Nix preserves it directly.
* **Prohibition of `:latest`:** Using `:latest` is strictly prohibited. The Nix compiler checks for `:latest` tags on all workshop images and raises an evaluation error if encountered. This guarantees that bare-metal worker nodes never run divergent or unverified cached image layers.

### Dynamic Git Commit Hash Tracking

When a lab cluster imports the workshops repository via Nix flakes (e.g. `inputs.workshops.url = "github:aivillage/workshops"`), Nix captures the repository's exact commit revision:
* `inputs.workshops.shortRev`: The 7-character Git commit SHA.
* If local uncommitted changes exist, `inputs.workshops.dirtyShortRev` is used.
* The manifest compiler injects this SHA across all rendered Kubernetes Deployment specs and Hub ConfigMaps.

### Continuous Integration with GitHub Actions

The `workshops` repository features an automated GitHub Actions workflow (`.github/workflows/publish-containers.yaml`):

1. **Trigger:** Fires on any push to `main` or feature branches (`feat/**`, `fix/**`).
2. **Build Execution:** Runs `nix run .#build-<name> -- --push` for each container target.
3. **Tagging Mechanism:** `scripts/build_container.sh` extracts `git rev-parse --short HEAD` and tags the built image as `ghcr.io/aivillage/workshops/<name>:<shortRev>`.
4. **Registry Push:** Pushes the immutable SHA-tagged image directly to GitHub Container Registry (`ghcr.io`).

Because the image tag produced by CI matches `inputs.workshops.shortRev` evaluated by Nix, updating the workshop flake input (`nix flake update workshops`) automatically references the corresponding newly built images.

### Broken Builds & Registry Verification

Nix evaluates manifests purely and offline; it does not query remote container registries during `cluster gen k8s`.

1. **Verify GitHub Actions Completion:** Always ensure the GitHub Actions workflow (`publish-containers.yaml`) has completed successfully on GitHub before updating `flake.lock` in the event repository (`lab1`).
2. **Pre-Deployment Registry Check:** Verify that the image exists in GHCR before rolling out to the cluster:
   ```bash
   podman pull ghcr.io/aivillage/workshops/<name>:<tag>
   # or
   skopeo inspect docker://ghcr.io/aivillage/workshops/<name>:<tag>
   ```
3. **Runtime Symptoms:** If an image build failed in CI or an invalid tag is specified, worker nodes will be unable to pull the image and the pod will enter `ImagePullBackOff` or `ErrImagePull`. Triage with `cluster status` or `kubectl -n workshop get pods`.

---

## 4. Local Development & Pre-Seed Weights

Challenge authors can build and validate containers locally before pushing to CI or deploying to the cluster.

### Running Local Container Builds via Nix

From within the `workshops` repository root:

```bash
# Build an individual container locally using Nix
nix run .#build-email-indirect-user

# Build a backend companion service
nix run .#build-email-indirect-service

# Build all containers declared in the repository
nix run .#build-all-images
```

Alternatively, enter the developer shell to access convenience wrappers:

```bash
nix develop

# Build with a custom local tag
build-email-indirect-user --tag dev-test

# Build and push directly to a custom registry
build-email-indirect-user --tag my-tag --push
```

### Pre-Seeding Model Weights in `/var/models`

During live events, attendee user containers and shared services send inference queries to the Tier 4 vLLM cluster. Model weights are never pulled over public WAN connections at runtime.

1. **Specify Required Model:** Authors must specify the required Hugging Face model path in `workshop.toml`:
   ```toml
   model = "google/gemma-3-4b-it"
   ```
2. **Offline Host-Path Mount:** On bare-metal GPU worker nodes, model weights reside under `/var/models/<model>` on local NVMe storage and are mounted read-only into vLLM pods.
3. **Synchronizing Weights to Workers:** Prior to the event, operators sync weights from the coordinator host to worker nodes:
   ```bash
   # Pre-seed weights across bare-metal GPU workers
   rsync -avzP /var/models/google/gemma-3-4b-it root@<worker-ip>:/var/models/google/
   ```

---

## 5. Activating in `lab.nix`

Once a challenge is authored, containerized, and pushed to the registry, activate it in the target cluster.

### Step 1: Update the Workshops Flake Input

In your lab directory (e.g. `lab1/flake.nix`), ensure the `workshops` flake input points to the relevant branch or commit:

```bash
nix flake update workshops
```

### Step 2: Register Workshop in `lab.nix`

Add the workshop identifier to `cluster.k8s.workshopHub.workshops` in `lab.nix`:

```nix
cluster.k8s.workshopHub = {
  enable = true;
  vip = "10.200.20.31";
  baseDomain = "lab.aivillage.local";
  workshops = [
    "llm-embeddings"
    "model-lab"
    "prompt-extraction"
    "rag-poisoning"
    "email-indirect"
    "my-new-challenge"  # Add new challenge here
  ];
  # ...
};
```

### Step 3: Regenerate Kubernetes Manifests

Recompile declarative cluster manifests:

```bash
cluster gen k8s
```

Verify that:
* The workshop appears in the Hub ConfigMap in `.cluster/k8s/addons/workshop-hub.yaml`.
* If a companion `[service]` was defined, its Deployment and Service manifests are generated in `.cluster/k8s/workshops.yaml`.

### Step 4: Apply to Cluster and Restart Hub

Apply the manifests to the live cluster and reload the Hub controller:

```bash
# Apply updated manifests to the Kubernetes cluster
cluster apply k8s

# Restart the Workshop Hub controller to load the new workshop catalog
kubectl rollout restart deployment workshop-hub -n workshop-hub-system
kubectl rollout status deployment workshop-hub -n workshop-hub-system
```

---

## 6. Cross-References

* [Operator Guide](operator-guide.md): On-site proctor commands, triage matrix, and emergency pod evacuation.
* [Workshop Architecture Reference](workshop-architecture.md): In-depth guide to network isolation, VIP routing, and session reaper mechanics.

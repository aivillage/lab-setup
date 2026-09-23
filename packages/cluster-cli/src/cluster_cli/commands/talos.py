import base64
import concurrent.futures
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple
import typer
import yaml
from rich.table import Table
from rich import box

from cluster_cli.config import (
    get_coordinator_host,
    get_machines_data,
    get_talosconfig_path,
    get_kubeconfig_path,
    is_local_host,
    is_pingable,
)
from cluster_cli.clients.coordinator import CoordinatorClient
from cluster_cli.clients.kubectl import get_nodes_info, run_kubectl
from cluster_cli.clients.talosctl import run_talosctl
from cluster_cli.views.console import (
    console,
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    CRIMSON,
    AMBER,
    print_header,
    print_success,
    print_error,
    print_warning,
    print_info,
    print_dim,
)
from cluster_cli.views.tables import merge_cluster_nodes


def gen_command(
    target: str = typer.Argument(
        ..., help="Target configuration type: 'talos', 'k8s', or 'secrets'"
    ),
    out_dir: Optional[str] = typer.Argument(
        None, help="Output directory or target file"
    ),
    force: bool = typer.Option(
        False, "-f", "--force", help="Overwrite existing secrets file without prompt"
    ),
) -> None:
    """Render Talos OS node configs, K8s manifests, or PKI secrets."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if target == "secrets":
        out_file_str = out_dir or "secrets/talos.yaml"
        out_file = Path(out_file_str)

        if out_file.exists() and not force:
            console.print(f"\n[bold {AMBER}][WARNING] {out_file} already exists![/bold {AMBER}]")
            console.print("  Regenerating PKI will replace the existing cluster secrets.")
            console.print("  A timestamped backup will be created automatically before overwriting.\n")
            confirm = typer.confirm(f"Are you sure you want to generate a new PKI secrets bundle for '{out_file}'?")
            if not confirm:
                print_warning("Secrets generation canceled. Files untouched.\n")
                return

        if out_file.exists():
            ts = time.strftime("%Y%m%d%H%M%S")
            bak_file = out_file.parent / f"{out_file.name}.bak-{ts}"
            try:
                shutil.copy2(out_file, bak_file)
                console.print(f"Creating timestamped backup of existing secrets at {bak_file}...")
            except Exception as e:
                print_warning(f"Could not create backup file: {e}")

        out_file.parent.mkdir(parents=True, exist_ok=True)
        print_info("Generating brand new Talos cluster PKI secrets...")

        with tempfile.NamedTemporaryFile(suffix=".yaml", delete=False) as raw_tmp:
            tmp_path = Path(raw_tmp.name)

        try:
            res_gen = subprocess.run(
                ["talosctl", "gen", "secrets", "-o", str(tmp_path), "--force"],
                capture_output=True,
                text=True,
            )
            if res_gen.returncode != 0:
                print_error(f"talosctl gen secrets failed: {res_gen.stderr.strip()}")
                raise typer.Exit(code=1)

            raw_content = tmp_path.read_text(encoding="utf-8")
            wrapped_content = yaml.dump({"talos-secrets": raw_content}, sort_keys=False)
            tmp_path.write_text(wrapped_content, encoding="utf-8")

            print_info(f"Encrypting secrets with SOPS into {out_file}...")
            res_enc = subprocess.run(
                ["sops", "--filename-override", str(out_file), "--encrypt", str(tmp_path)],
                capture_output=True,
                text=False,
            )
            if res_enc.returncode != 0:
                print_error(
                    f"sops --encrypt failed: {res_enc.stderr.decode('utf-8', errors='replace').strip()}"
                )
                raise typer.Exit(code=1)

            out_file.write_bytes(res_enc.stdout)
            try:
                out_file.chmod(0o600)
            except Exception:
                pass

            print_success(
                f"Successfully generated and encrypted cluster secrets to {out_file}!\n"
            )
        finally:
            tmp_path.unlink(missing_ok=True)

    elif target == "talos":
        dest_dir = Path(out_dir or ".cluster/talos")
        dest_dir.mkdir(parents=True, exist_ok=True)
        print_info(f"Rendering Talos machine configurations to {dest_dir}/...")

        secrets_file: Optional[Path] = None
        for cand in [Path("secrets/talos.yaml"), Path("secrets.yaml")]:
            if cand.exists() and cand.is_file():
                secrets_file = cand
                break

        temp_secrets: Optional[Path] = None
        try:
            secrets_arg: Optional[str] = None
            if secrets_file:
                res_dec = subprocess.run(
                    ["sops", "-d", str(secrets_file)],
                    capture_output=True,
                    text=True,
                )
                if res_dec.returncode == 0:
                    try:
                        data = yaml.safe_load(res_dec.stdout)
                        if (
                            isinstance(data, dict)
                            and "talos-secrets" in data
                            and isinstance(data["talos-secrets"], str)
                        ):
                            decrypted_content = data["talos-secrets"]
                        else:
                            decrypted_content = res_dec.stdout
                    except Exception:
                        decrypted_content = res_dec.stdout

                    with tempfile.NamedTemporaryFile(
                        mode="w", suffix=".yaml", delete=False
                    ) as raw_tmp:
                        raw_tmp.write(decrypted_content)
                        temp_secrets = Path(raw_tmp.name)
                    secrets_arg = str(temp_secrets)
                else:
                    print_warning(
                        f"Failed to decrypt {secrets_file} with SOPS: {res_dec.stderr.strip()}"
                    )

            gen_bin = shutil.which("generate-configs")
            if gen_bin:
                cmd = [gen_bin, str(dest_dir)]
                if secrets_arg:
                    cmd.append(secrets_arg)
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode == 0:
                    print_success(f"Successfully rendered Talos configs into {dest_dir}/\n")
                else:
                    print_error(f"generate-configs failed: {res.stderr.strip()}")
                    raise typer.Exit(code=1)
            else:
                console.print(f"Fetching rendered configs from Coordinator ({coordinator_host})...")
                machines = get_machines_data()
                for m in machines:
                    code, body = client.get_config(f"{m}.yaml")
                    if code == 200:
                        (dest_dir / f"{m}.yaml").write_text(body, encoding="utf-8")
                        console.print(f"  -> Saved {dest_dir / f'{m}.yaml'}")
                print_success(f"Talos configs synchronized to {dest_dir}/\n")
        finally:
            if temp_secrets:
                temp_secrets.unlink(missing_ok=True)

    elif target == "k8s":
        dest_dir = Path(out_dir or ".cluster/k8s")
        dest_dir.mkdir(parents=True, exist_ok=True)
        print_info(f"Rendering Kubernetes manifests to {dest_dir}/...")

        manifest_names = [
            "cilium.yaml",
            "nvidia-device-plugin.yaml",
            "workshop-hub.yaml",
            "workshops.yaml",
            "vllm.yaml",
        ]

        gen_bin = shutil.which("generate-patches")
        local_success = False

        if gen_bin:
            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_path = Path(tmp_dir)
                res = subprocess.run([gen_bin, str(tmp_path)], capture_output=True, text=True)
                if res.returncode == 0:
                    for manifest_name in manifest_names:
                        for cand in [
                            tmp_path / manifest_name,
                            tmp_path / "addons" / manifest_name,
                            tmp_path / "base-patches" / manifest_name,
                        ]:
                            if cand.is_file():
                                (dest_dir / manifest_name).write_text(cand.read_text(encoding="utf-8"), encoding="utf-8")
                                console.print(f"  -> Saved {dest_dir / manifest_name}")
                                break
                    local_success = True
                else:
                    print_warning(f"generate-patches failed: {res.stderr.strip()}, falling back to Coordinator")

        if not local_success:
            for manifest_name in manifest_names:
                code, body = client.get_config(manifest_name)
                if code == 200:
                    (dest_dir / manifest_name).write_text(body, encoding="utf-8")
                    console.print(f"  -> Saved {dest_dir / manifest_name}")
        print_success(f"Kubernetes manifests rendered to {dest_dir}/\n")

    else:
        print_error(
            f"Unknown gen target '{target}'. Use 'talos', 'k8s', or 'secrets'. Run 'cluster discover -w' to generate machines.nix."
        )
        raise typer.Exit(code=1)


def sync_kubeconfig_to_coordinator(kc_path: str, coordinator_host: str) -> None:
    """Synchronize local kubeconfig to spark2:~/.kube/config and /var/lib/coordinator/talos/kubeconfig if reachable."""
    p = Path(kc_path)
    if not p.is_file() or p.stat().st_size == 0:
        return
    content = p.read_bytes()
    if is_local_host(coordinator_host):
        for target in [
            Path.home() / ".kube" / "config",
            Path("/var/lib/coordinator/talos/kubeconfig"),
            Path("/var/lib/coordinator/k8s/kubeconfig"),
        ]:
            try:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                target.chmod(0o600)
            except Exception:
                pass
    else:
        sync_cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            "mkdir -p ~/.kube && cat > ~/.kube/config && sudo mkdir -p /var/lib/coordinator/talos /var/lib/coordinator/k8s && sudo cp ~/.kube/config /var/lib/coordinator/talos/kubeconfig && sudo cp ~/.kube/config /var/lib/coordinator/k8s/kubeconfig && sudo chmod 644 /var/lib/coordinator/talos/kubeconfig /var/lib/coordinator/k8s/kubeconfig && chmod 600 ~/.kube/config",
        ]
        try:
            res = subprocess.run(sync_cmd, input=content, capture_output=True, timeout=8.0)
            if res.returncode == 0:
                console.print(
                    f"  [{SAGE_GREEN}][OK][/{SAGE_GREEN}] Synchronized kubeconfig to {coordinator_host}:~/.kube/config & /var/lib/coordinator/talos/kubeconfig"
                )
        except Exception:
            pass


def apply_command(
    target: str = typer.Argument(..., help="Target configuration type: 'talos' or 'k8s'"),
    arg: Optional[str] = typer.Argument(
        None, help="Target node name (for talos) or manifest directory (for k8s)"
    ),
    mode: str = typer.Option(
        "auto", "--mode", "-m", help="Talos apply mode: 'auto', 'reboot', 'no-reboot', 'staged'"
    ),
) -> None:
    """Apply Talos node configuration or Kubernetes manifests."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if target == "talos":
        node = arg or "all"
        machines = get_machines_data()
        tc = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
        if not Path(tc).exists() and not is_local_host(coordinator_host):
            pull_secrets_command()
            tc = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
        target_nodes = list(machines.keys()) if node in ("all", "cluster") else [node]

        print_info(f"Applying Talos configuration to {', '.join(target_nodes)}...")
        success = True
        for n in target_nodes:
            conf_file = Path(f".cluster/talos/{n}.yaml")
            m_data = machines.get(n, {})
            node_ip = m_data.get("ip") or ""
            if not node_ip:
                net_ifaces = m_data.get("network-interfaces") or {}
                for iface_attrs in net_ifaces.values():
                    if isinstance(iface_attrs, dict) and iface_attrs.get("ip"):
                        if iface_attrs.get("role") in ("private", "cluster") or not node_ip:
                            node_ip = iface_attrs["ip"]
            node_ip = node_ip or n
            if not node_ip or node_ip == n:
                # First try querying K8s InternalIP
                try:
                    k8s_res = run_kubectl(
                        ["get", "node", n, "-o", "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}"],
                        coordinator_host=coordinator_host,
                    )
                    if k8s_res.returncode == 0 and k8s_res.stdout.strip():
                        node_ip = k8s_res.stdout.strip()
                except Exception:
                    pass

                # Second, if still unresolved, check merged cluster nodes from coordinator status
                if not node_ip or node_ip == n:
                    try:
                        c_status = client.get_status()
                        merged = merge_cluster_nodes(
                            machines,
                            c_status.get("wipe_data", {}),
                            c_status.get("discovered_nodes", []),
                        )
                        for m_node in merged:
                            if (
                                m_node.get("name") == n
                                and m_node.get("pxe_ip")
                                and m_node.get("pxe_ip") != "-"
                            ):
                                node_ip = m_node["pxe_ip"]
                                break
                    except Exception:
                        pass

            code, body = client.get_config(f"{n}.yaml")
            if code == 200:
                conf_file.parent.mkdir(parents=True, exist_ok=True)
                conf_file.write_text(body, encoding="utf-8")
            elif not conf_file.is_file():
                print_error(f"Could not find or fetch config for {n}")
                success = False
                continue

            cmd = [
                "talosctl",
                "--talosconfig",
                tc,
                "--endpoints",
                node_ip,
                "--nodes",
                node_ip,
                "apply-config",
                "--file",
                str(conf_file),
                "--mode",
                mode,
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0:
                print_success(f"Applied config to {n} ({node_ip})")
            else:
                print_error(f"Failed to apply config to {n} ({node_ip}): {res.stderr.strip()}")
                success = False
            if not success:
                raise typer.Exit(code=1)

    elif target == "k8s":
        manifest_dir = arg or ".cluster/k8s"
        kc = get_kubeconfig_path() or f"{os.getcwd()}/.cluster/k8s/kubeconfig"
        if not Path(kc).exists() and not is_local_host(coordinator_host):
            pull_secrets_command()
            kc = get_kubeconfig_path() or f"{os.getcwd()}/.cluster/k8s/kubeconfig"
        sync_kubeconfig_to_coordinator(kc, coordinator_host)
        print_info(f"Applying Kubernetes manifests from {manifest_dir}...")
        cmd = ["kubectl", "--kubeconfig", kc, "apply", "-f", manifest_dir]
        res = subprocess.run(cmd)
        if res.returncode != 0:
            raise typer.Exit(code=res.returncode)

    else:
        print_error(f"Unknown apply target '{target}'. Use 'talos' or 'k8s'.")
        raise typer.Exit(code=1)


def bootstrap_command(
    node: Optional[str] = typer.Option(
        None, "--node", "-n", help="Control plane node name or IP (default: auto-detected)"
    ),
    timeout: float = typer.Option(
        180.0, "--timeout", "-t", help="Timeout in seconds waiting for node to be ready for bootstrap"
    ),
) -> None:
    """Bootstrap ETCD cluster on control plane and synchronize credentials."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()
    wipe_data = status_data.get("wipe_data", {}) if status_data else {}
    discovered_nodes = status_data.get("discovered_nodes", []) if status_data else []
    machines = get_machines_data()
    merged_nodes = merge_cluster_nodes(machines, wipe_data)
    nodes_by_name = {n["name"]: n for n in merged_nodes}

    # Find control plane node and IP
    cp_name = "control"
    cp_ip = None
    for name, m_data in machines.items():
        if m_data.get("controlPlane", False):
            cp_name = name
            net_ifaces = m_data.get("network-interfaces") or {}
            for icfg in net_ifaces.values():
                if isinstance(icfg, dict) and icfg.get("ip") and (icfg.get("primary") or icfg.get("role") == "private"):
                    cp_ip = icfg["ip"]
                    break
            break

    if not cp_ip or cp_ip == "-":
        if cp_name in nodes_by_name and nodes_by_name[cp_name].get("pxe_ip") and nodes_by_name[cp_name]["pxe_ip"] != "-":
            cp_ip = nodes_by_name[cp_name]["pxe_ip"]
        elif wipe_data:
            for wmac, wentry in wipe_data.items():
                if isinstance(wentry, dict) and (wentry.get("name") == cp_name or wmac == cp_name):
                    pxe = wentry.get("pxe_ip")
                    if pxe and pxe != "-":
                        cp_ip = pxe
                        break

    if not cp_ip or cp_ip == "-":
        cp_ip = "10.200.10.211"

    target_ip = node or cp_ip
    tc = get_talosconfig_path() or ".cluster/talos/talosconfig"
    if not Path(tc).exists() and not is_local_host(coordinator_host):
        pull_secrets_command(".cluster")
        tc = get_talosconfig_path() or ".cluster/talos/talosconfig"

    print_header("AI Village Cluster Bootstrap Procedure")
    print_info(f"Targeting Control Plane Node: [{GOLD}]{cp_name}[/{GOLD}] ([{STEEL_BLUE}]{target_ip}[/{STEEL_BLUE}])")

    # Step 1: Poll node reachability and machined version
    console.print("  Waiting for Talos machined to complete installation / become reachable...")
    t0 = time.time()
    ready = False
    while time.time() - t0 < timeout:
        res = run_talosctl(
            ["-n", target_ip, "-e", target_ip, "version", "--short"],
            coordinator_host=coordinator_host,
        )
        if res.returncode == 0 and "Tag:" in res.stdout:
            ready = True
            break
        time.sleep(3)

    if not ready:
        print_warning(f"Node {target_ip} did not respond within {timeout:.0f}s. Attempting bootstrap anyway...")

    # Step 2: Fire talosctl bootstrap
    print_info("Bootstrapping ETCD cluster on control plane...")
    res_b = run_talosctl(
        ["--endpoints", target_ip, "--nodes", target_ip, "bootstrap"],
        coordinator_host=coordinator_host,
    )
    if res_b.returncode == 0:
        print_success("ETCD cluster bootstrap accepted successfully.")
    elif "already bootstrapped" in res_b.stderr.lower():
        print_info("ETCD cluster is already bootstrapped.")
    else:
        print_error(f"Bootstrap failed: {res_b.stderr.strip()}")
        raise typer.Exit(code=1)

    # Step 3: Fetch and synchronize kubeconfig
    print_info("Fetching Kubeconfig from Control Plane VIP...")
    kc_path = Path(".cluster/k8s/kubeconfig")
    kc_path.parent.mkdir(parents=True, exist_ok=True)
    if not is_local_host(coordinator_host):
        res_kc = run_talosctl(
            [
                "--endpoints",
                target_ip,
                "--nodes",
                target_ip,
                "kubeconfig",
                "/var/lib/coordinator/k8s/kubeconfig",
                "--force",
            ],
            coordinator_host=coordinator_host,
        )
        if res_kc.returncode == 0:
            ssh_cmd = [
                "ssh",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "StrictHostKeyChecking=no",
                f"admin@{coordinator_host}",
                "cat /var/lib/coordinator/k8s/kubeconfig",
            ]
            res_fetch = subprocess.run(ssh_cmd, capture_output=True)
            if res_fetch.returncode == 0 and res_fetch.stdout:
                kc_path.write_bytes(res_fetch.stdout)
                kc_path.chmod(0o600)
                print_success(f"Extracted and fetched kubeconfig to {kc_path}")
                sync_kubeconfig_to_coordinator(str(kc_path), coordinator_host)
            else:
                print_warning(
                    f"Could not fetch kubeconfig from coordinator over SSH: {res_fetch.stderr.decode('utf-8', errors='replace').strip()}"
                )
        else:
            print_warning(
                f"Could not extract kubeconfig on coordinator: {res_kc.stderr.strip()}"
            )
    else:
        res_kc = run_talosctl(
            [
                "--endpoints",
                target_ip,
                "--nodes",
                target_ip,
                "kubeconfig",
                str(kc_path),
                "--force",
            ],
            coordinator_host=coordinator_host,
        )
        if res_kc.returncode == 0 and kc_path.is_file():
            kc_path.chmod(0o600)
            print_success(f"Extracted kubeconfig to {kc_path}")
            sync_kubeconfig_to_coordinator(str(kc_path), coordinator_host)
        else:
            print_warning(
                f"Could not extract kubeconfig immediately: {res_kc.stderr.strip()}"
            )

    print_success("Cluster bootstrap procedure complete.\n")


def pull_secrets_command(
    target_dir: str = typer.Argument(
        ".cluster", help="Destination directory (default: .cluster)"
    ),
) -> None:
    """Fetch canonical secrets & talosconfig from Coordinator."""
    coordinator_host = get_coordinator_host()
    dest_str = target_dir if isinstance(target_dir, (str, Path)) else ".cluster"
    dest_path = Path(dest_str)

    print_info(f"Fetching secrets & configs from Coordinator ({coordinator_host})...")
    (dest_path / "talos").mkdir(parents=True, exist_ok=True)
    (dest_path / "k8s").mkdir(parents=True, exist_ok=True)

    # 1. talosconfig
    local_tc = Path("/var/lib/coordinator/talos/talosconfig")
    dest_tc = dest_path / "talos" / "talosconfig"
    if local_tc.is_file():
        console.print(f"  Copying local {local_tc}...")
        dest_tc.write_bytes(local_tc.read_bytes())
    else:
        console.print(f"  Pulling talosconfig over SSH from admin@{coordinator_host}...")
        cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            "cat /var/lib/coordinator/talos/talosconfig",
        ]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode == 0 and res.stdout:
            dest_tc.write_bytes(res.stdout)
    if dest_tc.is_file():
        dest_tc.chmod(0o600)

    # 2. kubeconfig
    local_kc = Path("/var/lib/coordinator/talos/kubeconfig")
    dest_kc = dest_path / "k8s" / "kubeconfig"
    if local_kc.is_file():
        console.print(f"  Copying local {local_kc}...")
        dest_kc.write_bytes(local_kc.read_bytes())
    else:
        console.print(f"  Pulling kubeconfig over SSH from admin@{coordinator_host}...")
        cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            "cat /var/lib/coordinator/talos/kubeconfig",
        ]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode == 0 and res.stdout:
            dest_kc.write_bytes(res.stdout)
    if dest_kc.is_file():
        dest_kc.chmod(0o600)

    # 3. Extract kubeconfig if missing locally but talosconfig exists
    if (not dest_kc.is_file() or dest_kc.stat().st_size == 0) and dest_tc.is_file():
        console.print("  Extracting kubeconfig via talosctl from control plane (10.200.10.30)...")
        extract_cmd = [
            "talosctl",
            "--talosconfig",
            str(dest_tc),
            "--endpoints",
            "10.200.10.30",
            "--nodes",
            "10.200.10.30",
            "kubeconfig",
            str(dest_kc),
        ]
        res_extract = subprocess.run(extract_cmd, capture_output=True, text=True)
        if res_extract.returncode == 0 and dest_kc.is_file():
            dest_kc.chmod(0o600)
            console.print(f"  [{SAGE_GREEN}][OK][/{SAGE_GREEN}] Extracted kubeconfig to {dest_kc}")
        else:
            console.print(f"  [{AMBER}][WARNING][/{AMBER}] Could not extract kubeconfig: {res_extract.stderr.strip()}")

    # 4. Automated Kubeconfig synchronization to Coordinator
    if dest_kc.is_file() and dest_kc.stat().st_size > 0:
        sync_kubeconfig_to_coordinator(str(dest_kc), coordinator_host)

    print_success(f"Successfully synchronized secrets to {dest_path}/\n")


# ── Cluster Cache & Model Operations ────────────────────────────

cache_app = typer.Typer(
    name="cache",
    help="Inspect, warm up, or synchronize container registry mirrors and model storage",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

images_app = typer.Typer(
    name="images",
    help="Inspect and warm up container registry mirrors",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

models_app = typer.Typer(
    name="models",
    help="Inspect, sync, and pull AI model storage and weights",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

cache_app.add_typer(images_app, name="images")
cache_app.add_typer(models_app, name="models")


# ── Canonical Image and Model Catalogs ──────────────────────────

DEFAULT_WORKSHOP_IMAGES = [
    "ghcr.io/nbhdai/workshop-hub:latest",
    "ghcr.io/nbhdai/workshop-sidecar:v0.1.0",
    "ghcr.io/nbhdai/yolo-l2-notebook:v0.1.0",
    "ghcr.io/nbhdai/yolo-l2-verification:v0.1.0",
    "ghcr.io/nbhdai/email-indirect-user:v0.1.0",
    "ghcr.io/nbhdai/email-indirect-service:v0.1.0",
    "ghcr.io/nbhdai/rag-poisoning-user:v0.1.0",
    "ghcr.io/nbhdai/rag-poisoning-service:v0.1.0",
    "ghcr.io/nbhdai/prompt-extraction-user:v0.1.0",
    "ghcr.io/nbhdai/prompt-extraction-service:v0.1.0",
    "ghcr.io/nbhdai/llm-embeddings:v0.1.0",
    "vllm/vllm-openai:v0.18.0-cu130",
]

DEFAULT_INFRA_IMAGES = [
    "quay.io/cilium/cilium:v1.15.5",
    "quay.io/cilium/operator-generic:v1.15.5",
    "nvcr.io/nvidia/k8s-device-plugin:v0.15.0",
    "registry:2",
    "nginx:latest",
]

DEFAULT_MODELS = [
    "google/gemma-4-31B-it",
    "diffusiongemma-26B-A4B-it",
    "meta-llama/Llama-3.1-8B-Instruct",
    "BAAI/bge-small-en-v1.5",
]

DEFAULT_MODEL_STORAGE_PATHS = [
    "/var/models",
    "/var/lib/models",
    "/var/lib/coordinator/models",
    ".cluster/models",
]


def get_kubectl_command(coordinator_host: str) -> str:
    """Returns the base kubectl command string appropriate for local or remote execution."""
    if is_local_host(coordinator_host):
        kc = get_kubeconfig_path()
        if kc and os.path.isfile(kc):
            return f"kubectl --kubeconfig {shlex.quote(kc)}"
        return "kubectl"
    else:
        return "kubectl --kubeconfig /var/lib/coordinator/talos/kubeconfig"


def detect_coordinator_models_source(
    coordinator_host: str, explicit_path: Optional[str] = None
) -> str:
    """Finds the best candidate model source directory on Coordinator."""
    if explicit_path:
        return explicit_path

    candidates = ["/var/lib/models", "/var/lib/coordinator/models"]
    check_script = " && ".join(
        f'if [ -d "{p}" ]; then echo "{p}"; exit 0; fi' for p in candidates
    )
    code, out, _ = run_remote_or_local(coordinator_host, check_script, timeout=5.0)
    found = out.strip().splitlines()[-1] if code == 0 and out.strip() else ""
    return found if found else "/var/lib/models"


# ── Remote & Local Execution Utilities ──────────────────────────

def run_remote_or_local(
    host: str,
    cmd: str | List[str],
    timeout: float = 20.0,
    user: str = "admin",
) -> Tuple[int, str, str]:
    """Executes a command locally if host is localhost, otherwise over SSH."""
    if is_local_host(host):
        if isinstance(cmd, str):
            res = subprocess.run(
                cmd, shell=True, capture_output=True, text=True, timeout=timeout
            )
        else:
            res = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout
            )
        return res.returncode, res.stdout, res.stderr
    else:
        cmd_str = cmd if isinstance(cmd, str) else " ".join(shlex.quote(a) for a in cmd)
        ssh_cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "StrictHostKeyChecking=no",
            "-A",
            f"{user}@{host}",
            cmd_str,
        ]
        try:
            res = subprocess.run(
                ssh_cmd, capture_output=True, text=True, timeout=timeout + 5
            )
            return res.returncode, res.stdout, res.stderr
        except Exception as e:
            return -1, "", str(e)


def detect_container_engine(host: str = "") -> Optional[str]:
    """Detects available container engine (docker or podman)."""
    if not host or is_local_host(host):
        if shutil.which("docker"):
            return "docker"
        if shutil.which("podman"):
            return "podman"
        if Path("/opt/homebrew/bin/podman").exists():
            return "/opt/homebrew/bin/podman"
        if Path("/opt/homebrew/bin/docker").exists():
            return "/opt/homebrew/bin/docker"
        return None
    else:
        code, out, _ = run_remote_or_local(
            host,
            "command -v docker || command -v podman || echo ''",
            timeout=5.0,
        )
        engine = out.strip().splitlines()[-1] if out.strip() else ""
        return engine if engine else None


def get_cluster_nodes(coordinator_host: str) -> List[Dict[str, Any]]:
    """Fetches merged list of declared and discovered cluster nodes."""
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()
    flake_specs = status_data.get("flake_specs", {})
    wipe_data = status_data.get("wipe_data", {})
    discovered_nodes = status_data.get("discovered_nodes", [])
    machines_data = get_machines_data()
    return merge_cluster_nodes(machines_data or flake_specs, wipe_data, discovered_nodes)


# ── Inspection Helpers ──────────────────────────────────────────

def inspect_registry_mirrors(coordinator_host: str) -> List[Dict[str, Any]]:
    """Inspects container registry mirror storage and systemd registry services on Coordinator."""
    results: List[Dict[str, Any]] = []

    # Canonical Coordinator systemd registry mirror services
    registry_configs = [
        {"name": "docker-io", "service": "docker-registry-docker-io", "port": 5001, "remote": "https://registry-1.docker.io", "path": "/var/lib/coordinator/registries/docker-io"},
        {"name": "ghcr-io", "service": "docker-registry-ghcr-io", "port": 5002, "remote": "https://ghcr.io", "path": "/var/lib/coordinator/registries/ghcr-io"},
        {"name": "registry-k8s-io", "service": "docker-registry-registry-k8s-io", "port": 5003, "remote": "https://registry.k8s.io", "path": "/var/lib/coordinator/registries/registry-k8s-io"},
        {"name": "quay-io", "service": "docker-registry-quay-io", "port": 5004, "remote": "https://quay.io", "path": "/var/lib/coordinator/registries/quay-io"},
        {"name": "gcr-io", "service": "docker-registry-gcr-io", "port": 5005, "remote": "https://gcr.io", "path": "/var/lib/coordinator/registries/gcr-io"},
    ]

    for r in registry_configs:
        # Check service status via systemctl is-active or socket connection
        is_running = False
        code, out, _ = run_remote_or_local(
            coordinator_host, f"systemctl is-active {r['service']}", timeout=5.0
        )
        if code == 0 and out.strip() == "active":
            is_running = True
        else:
            try:
                target_host = "127.0.0.1" if is_local_host(coordinator_host) else coordinator_host
                with socket.create_connection((target_host, r["port"]), timeout=1.0):
                    is_running = True
            except Exception:
                pass

        # Check storage size
        size_cmd = f"if [ -d '{r['path']}' ]; then du -sh '{r['path']}' | cut -f1; else echo '-'; fi"
        code, out, _ = run_remote_or_local(coordinator_host, size_cmd, timeout=5.0)
        storage_size = out.strip().splitlines()[-1] if code == 0 and out.strip() else "-"
        if storage_size == "":
            storage_size = "-"

        status_str = f"[{SAGE_GREEN}]RUNNING[/{SAGE_GREEN}]" if is_running else f"[{MUTED_GREY}]STOPPED[/{MUTED_GREY}]"

        results.append({
            "name": r["name"],
            "remote": r["remote"],
            "port": r["port"],
            "status": status_str,
            "storage_size": storage_size,
            "container": r["service"],
            "service": r["service"],
        })

    return results


inspect_registry_storage = inspect_registry_mirrors


def inspect_coordinator_model_queue(
    coordinator_host: str, storage_dir: Optional[str] = None
) -> List[Dict[str, Any]]:
    """Inspects declarative Hugging Face model caching services and lock state on Coordinator."""
    target_dir = storage_dir or "/var/lib/models"

    py_script = f"""import json, os, subprocess

storage_dir = "{target_dir}"
for candidate in [storage_dir, "/var/lib/models", "/var/lib/coordinator/models", "/var/models"]:
    if os.path.isdir(candidate):
        storage_dir = candidate
        break

lock_file = os.path.join(storage_dir, ".cache.lock")

# Check lock PIDs via fuser or lsof
lock_pids = []
if os.path.exists(lock_file):
    try:
        res = subprocess.run(["fuser", lock_file], capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip():
            lock_pids = [int(p) for p in res.stdout.strip().split() if p.isdigit()]
    except Exception:
        pass
    if not lock_pids:
        try:
            res = subprocess.run(["lsof", "-t", lock_file], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                lock_pids = [int(p) for p in res.stdout.strip().split() if p.isdigit()]
        except Exception:
            pass

holding_pids = set()
waiting_pids = set()
if lock_pids and os.path.exists("/proc/locks") and os.path.exists(lock_file):
    try:
        lock_ino = os.stat(lock_file).st_ino
        with open("/proc/locks", "r") as f:
            for line in f:
                if str(lock_ino) in line:
                    parts = line.strip().split()
                    if "->" in line:
                        for p in parts:
                            if p.isdigit() and int(p) in lock_pids:
                                waiting_pids.add(int(p))
                    else:
                        for p in parts:
                            if p.isdigit() and int(p) in lock_pids:
                                holding_pids.add(int(p))
    except Exception:
        pass

if lock_pids and not holding_pids:
    holding_pids.add(lock_pids[0])
    for p in lock_pids[1:]:
        waiting_pids.add(p)

units_raw = ""
try:
    res = subprocess.run(
        ["systemctl", "list-units", "--all", "--type=service", "--no-legend", "--no-pager", "coordinator-model-cache-*"],
        capture_output=True, text=True
    )
    if res.returncode == 0:
        units_raw = res.stdout
except Exception:
    pass

unit_files_raw = ""
try:
    res = subprocess.run(
        ["systemctl", "list-unit-files", "--no-legend", "--no-pager", "coordinator-model-cache-*"],
        capture_output=True, text=True
    )
    if res.returncode == 0:
        unit_files_raw = res.stdout
except Exception:
    pass

unit_names = set()
for line in units_raw.splitlines():
    tokens = line.strip().split()
    if tokens and tokens[0].startswith("coordinator-model-cache-"):
        unit_names.add(tokens[0])
for line in unit_files_raw.splitlines():
    tokens = line.strip().split()
    if tokens and tokens[0].startswith("coordinator-model-cache-"):
        unit_names.add(tokens[0])

default_models = [
    "google/gemma-4-31B-it",
    "diffusiongemma-26B-A4B-it",
    "meta-llama/Llama-3.1-8B-Instruct",
    "BAAI/bge-small-en-v1.5",
]

known_units = list(unit_names)
if not known_units:
    for m in default_models:
        sanitized = m.replace("/", "-").replace(".", "-")
        known_units.append(f"coordinator-model-cache-{{sanitized}}.service")

results = []
for u in sorted(known_units):
    show_props = {{}}
    try:
        res = subprocess.run(
            ["systemctl", "show", u, "--property=Id,Description,ActiveState,SubState,Result,MainPID,ControlPID"],
            capture_output=True, text=True
        )
        if res.returncode == 0:
            for pline in res.stdout.splitlines():
                if "=" in pline:
                    k, v = pline.split("=", 1)
                    show_props[k.strip()] = v.strip()
    except Exception:
        pass

    desc = show_props.get("Description", "")
    model_id = ""
    if desc.startswith("AI Village Model Cache:"):
        model_id = desc.replace("AI Village Model Cache:", "").strip()
    if not model_id:
        base = u.replace("coordinator-model-cache-", "").replace(".service", "")
        matched = next((m for m in default_models if m.replace("/", "-").replace(".", "-") == base), base)
        model_id = matched

    active_state = show_props.get("ActiveState", "inactive")
    sub_state = show_props.get("SubState", "dead")
    result = show_props.get("Result", "")
    main_pid = int(show_props.get("MainPID", 0) or 0)
    control_pid = int(show_props.get("ControlPID", 0) or 0)

    model_path = os.path.join(storage_dir, model_id)
    size_on_disk = "-"
    if os.path.isdir(model_path):
        try:
            res = subprocess.run(["du", "-sh", model_path], capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                size_on_disk = res.stdout.strip().split()[0]
        except Exception:
            pass

    is_holding = (main_pid in holding_pids or control_pid in holding_pids)
    is_waiting = (main_pid in waiting_pids or control_pid in waiting_pids)

    if (active_state in ("active", "activating") and sub_state == "running") and lock_pids:
        if not is_holding and not is_waiting:
            try:
                cg_res = subprocess.run(["systemctl", "status", u], capture_output=True, text=True)
                for lp in lock_pids:
                    if str(lp) in cg_res.stdout:
                        if lp in holding_pids:
                            is_holding = True
                        else:
                            is_waiting = True
            except Exception:
                pass
            if not is_holding and not is_waiting:
                if len(holding_pids) == 0:
                    is_holding = True
                else:
                    is_waiting = True

    lock_state = "Idle"
    if is_holding:
        lock_state = "Holding Lock"
    elif is_waiting:
        lock_state = "Waiting"

    if active_state == "active" and sub_state == "exited" and result in ("success", ""):
        service_status = "[PASS] Present & Verified"
        lock_state = "Idle"
    elif active_state in ("active", "activating") and sub_state == "running":
        if is_waiting or (lock_pids and not is_holding):
            service_status = "[WAIT] Queued in Line"
            lock_state = "Waiting"
        else:
            service_status = "[SYNC] In-Progress / Downloading"
            lock_state = "Holding Lock"
    elif active_state == "failed" or result in ("exit-code", "timeout", "failed"):
        service_status = "[ERROR]"
        lock_state = "Idle"
    elif active_state == "inactive" and sub_state == "dead":
        if lock_pids:
            service_status = "[WAIT] Queued in Line"
            lock_state = "Waiting"
        elif size_on_disk != "-" and size_on_disk != "0":
            service_status = "[PASS] Present & Verified"
            lock_state = "Idle"
        else:
            service_status = "[WAIT] Queued in Line"
            lock_state = "Idle"
    else:
        if is_waiting:
            service_status = "[WAIT] Queued in Line"
        elif is_holding:
            service_status = "[SYNC] In-Progress / Downloading"
        else:
            service_status = "[" + active_state + "]"

    results.append({{
        "model": model_id,
        "service": u,
        "status": service_status,
        "size": size_on_disk,
        "lock_state": lock_state,
        "active_state": active_state,
        "sub_state": sub_state,
    }})

print(json.dumps(results))
"""
    encoded = base64.b64encode(py_script.encode("utf-8")).decode("ascii")
    cmd = f'PYTHON_BIN=$(command -v python3 2>/dev/null || find /nix/store -maxdepth 3 -name python3 2>/dev/null | head -n1 || echo python3); "$PYTHON_BIN" -c "import base64; exec(base64.b64decode(\'{encoded}\').decode(\'utf-8\'))"'
    code, out, _ = run_remote_or_local(coordinator_host, cmd, timeout=12.0)
    if code == 0 and out.strip():
        for line in reversed(out.strip().splitlines()):
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                try:
                    return json.loads(line)
                except Exception:
                    pass
        idx = out.rfind("[")
        if idx != -1:
            try:
                return json.loads(out[idx:])
            except Exception:
                pass

    results = []
    for model in DEFAULT_MODELS:
        results.append({
            "model": model,
            "service": f"coordinator-model-cache-{model.replace('/', '-').replace('.', '-')}.service",
            "status": "[WAIT] Queued in Line",
            "size": "-",
            "lock_state": "Idle",
            "active_state": "inactive",
            "sub_state": "dead",
        })
    return results


def _parse_bytes_value(raw: Any) -> Optional[float]:
    """Parses a byte count from an int, float, or string like '142.5G', '510GB', '547608330240'."""
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        return float(raw)
    s = str(raw).strip()
    if not s or s == "-":
        return None
    if s.isdigit():
        return float(s)
    s_clean = s.replace("iB", "B").replace(" ", "").upper()
    units = {
        "T": 1024 ** 4,
        "TB": 1024 ** 4,
        "G": 1024 ** 3,
        "GB": 1024 ** 3,
        "M": 1024 ** 2,
        "MB": 1024 ** 2,
        "K": 1024,
        "KB": 1024,
        "B": 1,
    }
    for unit, mult in sorted(units.items(), key=lambda x: -len(x[0])):
        if s_clean.endswith(unit):
            num_part = s_clean[:-len(unit)].strip()
            try:
                return float(num_part) * mult
            except ValueError:
                pass
    try:
        return float(s)
    except ValueError:
        return None


def _format_size_gb(size_bytes: float) -> str:
    """Formats bytes into human readable string e.g. '510G', '142.5G', '133G', '500M'."""
    if size_bytes <= 0:
        return "0G"
    gb = size_bytes / (1024 ** 3)
    if gb >= 1.0:
        if abs(gb - round(gb)) < 0.05:
            return f"{int(round(gb))}G"
        else:
            return f"{gb:.1f}G"
    elif size_bytes >= 1024 ** 2:
        mb = size_bytes / (1024 ** 2)
        if abs(mb - round(mb)) < 0.05:
            return f"{int(round(mb))}M"
        else:
            return f"{mb:.1f}M"
    elif size_bytes >= 1024:
        kb = size_bytes / 1024
        return f"{int(round(kb))}K"
    else:
        return f"{int(size_bytes)}B"


def _inspect_model_storage_talos(
    host: str, path: str = "/var/models", res_data: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """Inspects model storage on a Talos OS node using talosctl."""
    if res_data is None:
        res_data = {
            "host": host,
            "path": path,
            "exists": False,
            "size": "-",
            "used": "-",
            "avail": "-",
            "models": [],
            "error": None,
        }

    talosconfig = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
    base_cmd = ["talosctl"]
    if talosconfig and os.path.isfile(talosconfig):
        base_cmd.extend(["--talosconfig", talosconfig])
    base_cmd.extend(["-n", host, "-e", host])

    # 1. talosctl usage /var to extract directory sizes
    models_bytes: Optional[float] = None
    var_total_bytes: Optional[float] = None
    try:
        usage_res = subprocess.run(
            base_cmd + ["usage", "/var"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if usage_res.returncode == 0:
            norm_path = path.rstrip("/")
            path_base = os.path.basename(norm_path)
            for line in usage_res.stdout.splitlines():
                line_str = line.strip()
                if not line_str or line_str.startswith("NODE") or line_str.startswith("SIZE") or line_str.startswith("---"):
                    continue
                tokens = line_str.split()
                if len(tokens) >= 2:
                    name_str = tokens[-1]
                    size_str = tokens[-2]
                    try:
                        if name_str in ("models", path_base, norm_path):
                            models_bytes = float(size_str)
                            res_data["used"] = _format_size_gb(models_bytes)
                        elif name_str == ".":
                            var_total_bytes = float(size_str)
                    except ValueError:
                        pass
    except Exception:
        pass

    if models_bytes is None:
        try:
            usage_path_res = subprocess.run(
                base_cmd + ["usage", path],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if usage_path_res.returncode == 0:
                for line in usage_path_res.stdout.splitlines():
                    line_str = line.strip()
                    if not line_str or line_str.startswith("NODE") or line_str.startswith("SIZE") or line_str.startswith("---"):
                        continue
                    tokens = line_str.split()
                    if len(tokens) >= 2 and tokens[-1] == ".":
                        try:
                            models_bytes = float(tokens[-2])
                            res_data["used"] = _format_size_gb(models_bytes)
                            break
                        except ValueError:
                            pass
        except Exception:
            pass

    # 2. talosctl get discoveredvolumes to extract total capacity and available space
    total_cap_gb: Optional[float] = None
    try:
        vol_res = subprocess.run(
            base_cmd + ["get", "discoveredvolumes"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if vol_res.returncode == 0:
            for line in vol_res.stdout.splitlines():
                line_str = line.strip()
                if not line_str or line_str.startswith("NODE") or line_str.startswith("---"):
                    continue
                if "dm-1" in line_str or "EPHEMERAL" in line_str:
                    m = re.search(r"(\d+(?:\.\d+)?)\s*(GB|TB|MB|G|T|M)\b", line_str, re.IGNORECASE)
                    if m:
                        num = float(m.group(1))
                        unit = m.group(2).upper()
                        if unit in ("TB", "T"):
                            total_cap_gb = num * 1000.0
                        elif unit in ("MB", "M"):
                            total_cap_gb = num / 1000.0
                        else:
                            total_cap_gb = num
                        break

        if total_cap_gb is None:
            vol_res_json = subprocess.run(
                base_cmd + ["get", "discoveredvolumes", "-o", "json"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if vol_res_json.returncode == 0 and vol_res_json.stdout.strip():
                raw_out = vol_res_json.stdout.strip()
                json_items = []
                if raw_out.startswith("["):
                    json_items = json.loads(raw_out)
                else:
                    for l in raw_out.splitlines():
                        l_str = l.strip()
                        if l_str.startswith("{") and l_str.endswith("}"):
                            try:
                                json_items.append(json.loads(l_str))
                            except Exception:
                                pass
                for item in json_items:
                    if not isinstance(item, dict):
                        continue
                    spec = item.get("spec", {})
                    meta = item.get("metadata", {})
                    vol_id = str(meta.get("id", "") or spec.get("devName", "") or "")
                    vol_name = str(spec.get("name", "") or "")
                    size_raw = spec.get("size")
                    if "dm-1" in vol_id or "EPHEMERAL" in vol_name or vol_id == "dm-1" or vol_name == "EPHEMERAL":
                        cap_bytes = _parse_bytes_value(size_raw)
                        if cap_bytes:
                            total_cap_gb = cap_bytes / 1e9
                            break
    except Exception:
        pass

    if total_cap_gb is not None:
        res_data["size"] = f"{int(round(total_cap_gb))}G"
        var_used = var_total_bytes if var_total_bytes is not None else (models_bytes if models_bytes is not None else 0.0)
        avail_gb = max(0.0, total_cap_gb - (var_used / 1e9))
        res_data["avail"] = f"{int(round(avail_gb))}G"

    # 3. talosctl list /var/models to discover model subdirectories
    discovered_models = []
    list_success = False
    try:
        list_res = subprocess.run(
            base_cmd + ["list", path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if list_res.returncode == 0:
            list_success = True
            ignored_names = {".", "..", ".cache", "test.txt"}
            for line in list_res.stdout.splitlines():
                line_str = line.strip()
                if not line_str or line_str.startswith("NODE") or line_str.startswith("---"):
                    continue
                tokens = line_str.split()
                if not tokens:
                    continue

                cand_name = ""
                is_dir = True
                if len(tokens) >= 2 and tokens[-1] in ("f", "d"):
                    is_dir = (tokens[-1] == "d")
                    cand_name = tokens[-2]
                else:
                    cand_name = tokens[-1]

                cand_clean = os.path.basename(cand_name.rstrip("/"))
                if not cand_clean or cand_clean in ignored_names or cand_clean.startswith(".") or cand_clean.endswith(".txt") or not is_dir:
                    continue
                discovered_models.append(cand_clean)
    except Exception:
        pass

    if list_success or discovered_models or models_bytes is not None:
        res_data["exists"] = True
        res_data["models"] = list(dict.fromkeys(discovered_models))
        res_data["error"] = None
    elif total_cap_gb is not None:
        res_data["exists"] = False
        res_data["error"] = "Models directory not found"
    else:
        res_data["error"] = f"Talos node unreachable or talosctl failed ({host})"

    return res_data


def inspect_model_storage(host: str, path: str = "/var/models") -> Dict[str, Any]:
    """Inspects model storage usage and detected model directories on a target host."""
    res_data = {
        "host": host,
        "path": path,
        "exists": False,
        "size": "-",
        "used": "-",
        "avail": "-",
        "models": [],
        "error": None,
    }

    check_cmd = f"""
    if [ -d "{path}" ]; then
        echo "__EXISTS__"
        df -h "{path}" | awk 'NR==2 {{print $2, $3, $4}}'
        echo "__DU__"
        du -sh "{path}" 2>/dev/null | cut -f1
        echo "__MODELS__"
        find "{path}" -maxdepth 3 -type d 2>/dev/null
    else
        echo "__MISSING__"
    fi
    """
    code, out, err = run_remote_or_local(host, check_cmd, timeout=8.0)
    if code != 0:
        # Fallback for Talos OS nodes via talosctl if SSH failed
        talos_res = _inspect_model_storage_talos(host, path, res_data)
        if talos_res.get("exists") or talos_res.get("size") != "-" or talos_res.get("models"):
            return talos_res
        res_data["error"] = err.strip() or talos_res.get("error") or "Host unreachable"
        return res_data

    if "__MISSING__" in out:
        res_data["error"] = err.strip() or "Directory not found"
        return res_data

    res_data["exists"] = True
    parts = out.split("__DU__")
    if len(parts) >= 2:
        df_part = parts[0].replace("__EXISTS__", "").strip()
        df_tokens = df_part.split()
        if len(df_tokens) >= 3:
            res_data["size"] = df_tokens[0]
            res_data["used"] = df_tokens[1]
            res_data["avail"] = df_tokens[2]

        rest = parts[1]
        du_and_models = rest.split("__MODELS__")
        if len(du_and_models) >= 2:
            res_data["used_dir"] = du_and_models[0].strip()
            model_dirs = [d.strip() for d in du_and_models[1].strip().splitlines() if d.strip() and d.strip() != path]
            # Filter to leaf/meaningful model dirs
            filtered = []
            for d in model_dirs:
                rel = os.path.relpath(d, path)
                if rel and not rel.startswith(".") and "/" in rel:
                    filtered.append(rel)
                elif rel and not rel.startswith("."):
                    filtered.append(rel)
            res_data["models"] = list(dict.fromkeys(filtered))

    return res_data


# ── CLI Commands: Status ────────────────────────────────────────

@cache_app.command(name="status")
def cache_status_command(
    models_path: str = typer.Option(
        "/var/models", "--models-path", "-p", help="Base model storage directory path on worker nodes"
    ),
) -> None:
    """Inspect registry mirror storage on Coordinator and model storage on Coordinator & nodes."""
    coordinator_host = get_coordinator_host()
    print_header("AI Village Cluster Cache Status", f"(Coordinator: {coordinator_host})")

    # 1. Container Registry Mirrors Table
    console.print(f"[bold {GOLD}]Container Registry Mirrors (Coordinator)[/bold {GOLD}]")
    reg_data = inspect_registry_mirrors(coordinator_host)

    reg_table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    reg_table.add_column("Mirror Name", style=f"bold {GOLD}")
    reg_table.add_column("Upstream Remote", style=MUTED_GREY)
    reg_table.add_column("Local Port", style=STEEL_BLUE)
    reg_table.add_column("Service", style=MUTED_GREY)
    reg_table.add_column("Status")
    reg_table.add_column("Cache Size", style=STEEL_BLUE)

    for r in reg_data:
        reg_table.add_row(
            r["name"],
            r["remote"],
            str(r["port"]),
            r.get("service", r.get("container", "-")),
            r["status"],
            r["storage_size"],
        )
    console.print(reg_table)
    console.print()

    # 2. Coordinator Model Caching Queue Table
    console.print(f"[bold {GOLD}]Coordinator Model Caching Queue[/bold {GOLD}]")
    coord_src = detect_coordinator_models_source(coordinator_host)
    queue_data = inspect_coordinator_model_queue(coordinator_host, coord_src)

    queue_table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    queue_table.add_column("Model Identifier", style=f"bold {GOLD}")
    queue_table.add_column("Service Status")
    queue_table.add_column("Size on Disk", style=STEEL_BLUE)
    queue_table.add_column("Lock State")

    for q in queue_data:
        status_str = q["status"]
        if "[PASS]" in status_str:
            status_display = f"[{SAGE_GREEN}]{status_str}[/{SAGE_GREEN}]"
        elif "[SYNC]" in status_str:
            status_display = f"[{STEEL_BLUE}]{status_str}[/{STEEL_BLUE}]"
        elif "[WAIT]" in status_str:
            status_display = f"[{AMBER}]{status_str}[/{AMBER}]"
        elif "[ERROR]" in status_str:
            status_display = f"[{CRIMSON}]{status_str}[/{CRIMSON}]"
        else:
            status_display = status_str

        lock_str = q["lock_state"]
        if lock_str == "Holding Lock":
            lock_display = f"[{STEEL_BLUE}]{lock_str}[/{STEEL_BLUE}]"
        elif lock_str == "Waiting":
            lock_display = f"[{AMBER}]{lock_str}[/{AMBER}]"
        else:
            lock_display = f"[{MUTED_GREY}]{lock_str}[/{MUTED_GREY}]"

        queue_table.add_row(
            q["model"],
            status_display,
            q["size"],
            lock_display,
        )
    console.print(queue_table)
    console.print()

    # 3. HostPath & Model Storage Status
    console.print(f"[bold {GOLD}]HostPath Model Storage Status[/bold {GOLD}]")
    nodes = get_cluster_nodes(coordinator_host)
    k8s_nodes, _ = get_nodes_info(coordinator_host=coordinator_host)

    model_table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    model_table.add_column("Node", style=f"bold {GOLD}")
    model_table.add_column("Role", style=STEEL_BLUE)
    model_table.add_column("PXE / Internal IP", style=STEEL_BLUE)
    model_table.add_column("Path / Mount", style=MUTED_GREY)
    model_table.add_column("Capacity", style=STEEL_BLUE)
    model_table.add_column("Used", style=AMBER)
    model_table.add_column("Avail", style=SAGE_GREEN)
    model_table.add_column("Cached Models")

    # Check coordinator storage
    coord_src = detect_coordinator_models_source(coordinator_host)
    coord_storage = inspect_model_storage(coordinator_host, coord_src)
    if not coord_storage["exists"]:
        for alt_path in DEFAULT_MODEL_STORAGE_PATHS:
            if alt_path != coord_src:
                alt_storage = inspect_model_storage(coordinator_host, alt_path)
                if alt_storage["exists"]:
                    coord_storage = alt_storage
                    break

    coord_models_str = ", ".join(coord_storage["models"][:3]) if coord_storage["models"] else "-"
    if len(coord_storage["models"]) > 3:
        coord_models_str += f" (+{len(coord_storage['models']) - 3} more)"

    model_table.add_row(
        f"{coordinator_host} (Coord)",
        "Coordinator",
        "127.0.0.1" if is_local_host(coordinator_host) else coordinator_host,
        coord_storage["path"],
        coord_storage["size"],
        coord_storage["used"],
        coord_storage["avail"],
        coord_models_str if coord_storage["exists"] else f"[{MUTED_GREY}]Not Mounted[/{MUTED_GREY}]",
    )

    # Check each cluster worker node
    for node in nodes:
        if node.get("controlPlane", False) or node.get("role") == "ControlPlane":
            continue
        node_name = node["name"]
        role = node.get("role", "Worker")

        k8s_info = k8s_nodes.get(node_name)
        k8s_ready = k8s_info and k8s_info.get("status") == "Ready"
        k8s_ip = k8s_info.get("ip") if k8s_info else None
        node_ip = k8s_ip or node.get("pxe_ip", "-")
        is_alive = (node_ip and node_ip != "-" and is_pingable(node_ip, coordinator_host=coordinator_host)) or k8s_ready

        if is_alive:
            node_storage = inspect_model_storage(node_ip, models_path)
            models_summary = ", ".join(node_storage["models"][:3]) if node_storage["models"] else "-"
            if len(node_storage["models"]) > 3:
                models_summary += f" (+{len(node_storage['models']) - 3} more)"

            storage_status = models_summary if node_storage["exists"] else f"[{SAGE_GREEN}]HostPath Ready (K8s)[/{SAGE_GREEN}]" if k8s_ready else f"[{AMBER}]Directory Missing[/{AMBER}]"

            model_table.add_row(
                node_name,
                role,
                node_ip,
                node_storage["path"],
                node_storage["size"],
                node_storage["used"],
                node_storage["avail"],
                storage_status,
            )
        else:
            model_table.add_row(
                node_name,
                role,
                node_ip,
                models_path,
                "-",
                "-",
                "-",
                f"[{CRIMSON}]Offline / Unreachable[/{CRIMSON}]",
            )

    console.print(model_table)
    console.print()
    print_dim("Use `cluster cache warmup` or `cluster cache sync` to synchronize models across worker nodes.\n")


# ── CLI Commands: Warmup ────────────────────────────────────────

@cache_app.command(name="warmup")
def cache_warmup_command(
    images: bool = typer.Option(True, "--images/--no-images", help="Warm up container image mirrors"),
    models: bool = typer.Option(True, "--models/--no-models", help="Synchronize model weights across worker nodes"),
    node: Optional[List[str]] = typer.Option(None, "--node", "-n", help="Target specific worker node(s)"),
    source_dir: Optional[str] = typer.Option(None, "--source", "-s", help="Source model directory on Coordinator"),
    target_dir: str = typer.Option("/var/models", "--target", "-t", help="Target model directory on worker nodes"),
    engine: Optional[str] = typer.Option(None, "--engine", "-e", help="Container engine (docker/podman)"),
) -> None:
    """Warms container image mirrors and synchronizes model weights across cluster nodes."""
    print_header("AI Village Cluster Cache Warmup Procedure")

    if images:
        console.print(f"\n[bold {STEEL_BLUE}]=== Phase 1: Container Image Mirror Warmup ===[/bold {STEEL_BLUE}]")
        images_warmup_command(all_images=True, engine=engine)

    if models:
        console.print(f"\n[bold {STEEL_BLUE}]=== Phase 2: Kubernetes Staging Model Synchronization ===[/bold {STEEL_BLUE}]")
        cache_sync_command(node=node, source_dir=source_dir, target_dir=target_dir)

    console.print()
    print_success("Cluster cache warmup complete.")


# ── CLI Commands: Sync ──────────────────────────────────────────

def deploy_staging_pod(
    kubectl_cmd: str,
    coordinator_host: str,
    pod_name: str,
    node_name: str,
    target_dir: str,
    is_hub: bool = False,
) -> bool:
    """Deploys a lightweight staging pod pinned to node_name with target_dir mounted at /models."""
    # 1. Clean up any leftover previous pod
    run_remote_or_local(
        coordinator_host,
        f"{kubectl_cmd} delete pod {pod_name} --namespace kube-system --ignore-not-found=true --grace-period=0 --force 2>/dev/null",
        timeout=15.0,
    )

    # 2. Deploy temporary lightweight staging pod pinned to target node
    hub_entrypoint = [
        "/bin/sh",
        "-c",
        (
            "mkdir -p /models && "
            "printf 'port = 8730\\naddress = 0.0.0.0\\nuse chroot = false\\nread only = false\\n\\n[models]\\npath = /models\\ncomment = AI Village Model Hub\\nread only = false\\nlist = true\\n' > /tmp/rsyncd.conf && "
            "exec rsync --daemon --config=/tmp/rsyncd.conf --port=8730 --no-detach"
        ),
    ]
    worker_entrypoint = ["/bin/sh", "-c", "mkdir -p /models && sleep 3600"]

    pod_manifest = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": pod_name,
            "namespace": "kube-system",
            "labels": {
                "app.kubernetes.io/name": "model-syncer",
                "app.kubernetes.io/managed-by": "cluster-cli",
            },
        },
        "spec": {
            "nodeName": node_name,
            "restartPolicy": "Never",
            "tolerations": [
                {
                    "key": "nvidia.com/gpu",
                    "operator": "Exists",
                    "effect": "NoSchedule",
                },
                {
                    "key": "node-role.kubernetes.io/control-plane",
                    "operator": "Exists",
                    "effect": "NoSchedule",
                },
                {
                    "key": "node-role.kubernetes.io/master",
                    "operator": "Exists",
                    "effect": "NoSchedule",
                },
            ],
            "containers": [
                {
                    "name": "syncer",
                    "image": "eeacms/rsync:latest",
                    "command": hub_entrypoint if is_hub else worker_entrypoint,
                    "securityContext": {"runAsUser": 0},
                    "volumeMounts": [
                        {
                            "name": "models-storage",
                            "mountPath": "/models",
                        }
                    ],
                }
            ],
            "volumes": [
                {
                    "name": "models-storage",
                    "hostPath": {
                        "path": target_dir,
                        "type": "DirectoryOrCreate",
                    },
                }
            ],
        },
    }

    if is_hub:
        pod_manifest["spec"]["hostNetwork"] = True

    pod_json = json.dumps(pod_manifest)
    deploy_cmd = f"echo {shlex.quote(pod_json)} | {kubectl_cmd} apply -f - >/dev/null"
    dep_code, _, _ = run_remote_or_local(coordinator_host, deploy_cmd, timeout=20.0)
    if dep_code != 0:
        return False

    # 3. Wait for pod to be running / ready
    wait_cmd = f"{kubectl_cmd} wait --namespace kube-system --for=condition=Ready pod/{pod_name} --timeout=90s"
    wait_code, _, _ = run_remote_or_local(coordinator_host, wait_cmd, timeout=100.0)
    return wait_code == 0


@cache_app.command(name="sync")
def cache_sync_command(
    node: Optional[List[str]] = typer.Option(
        None, "--node", "-n", help="Target worker node name(s) (e.g. worker1)"
    ),
    source_dir: Optional[str] = typer.Option(
        None, "--source", "-s", help="Source model storage path on Coordinator (default: auto-detected /var/lib/models)"
    ),
    target_dir: str = typer.Option(
        "/var/models", "--target", "-t", help="Target model storage path on worker nodes"
    ),
    model: Optional[str] = typer.Option(
        None, "--model", "-m", help="Specific model subfolder or name to sync instead of full directory"
    ),
    canary: bool = typer.Option(
        False, "--canary", "-c", help="Sync a lightweight canary file to verify intra-cluster staging pod transfer without sending full model weights"
    ),
) -> None:
    """Synchronizes AI model weights from Coordinator to worker nodes via hierarchical K8s staging pod distribution."""
    coordinator_host = get_coordinator_host()
    kubectl_cmd = get_kubectl_command(coordinator_host)

    # 1. Resolve source directory on Coordinator
    src_path = detect_coordinator_models_source(coordinator_host, source_dir)
    print_header("AI Village Model Storage Synchronization", f"(Source: {coordinator_host}:{src_path})")

    # Verify source directory exists on coordinator
    code, out, _ = run_remote_or_local(
        coordinator_host,
        f"if [ -d '{src_path}' ]; then du -sh '{src_path}' 2>/dev/null | cut -f1; else echo '__MISSING__'; fi",
        timeout=10.0,
    )
    if code != 0 or "__MISSING__" in out:
        print_error(f"Source directory '{src_path}' does not exist on Coordinator ({coordinator_host}).")
        raise typer.Exit(code=1)

    src_size = out.strip().splitlines()[-1] if out.strip() else "0B"
    print_info(f"Coordinator source directory: [{STEEL_BLUE}]{src_path}[/{STEEL_BLUE}] (Size: [{GOLD}]{src_size}[/{GOLD}])")

    # Setup canary or model filtering if requested
    clean_model: Optional[str] = None
    model_identifier: str = "Full Catalog (All Models)"
    if canary:
        model_identifier = "canary (.canary_sync)"
        print_info("Canary mode enabled: verifying transfer via lightweight canary file (.canary_sync)...")
        canary_cmd = f"mkdir -p '{src_path}' && date -u +%Y-%m-%dT%H:%M:%SZ > '{src_path}/.canary_sync'"
        run_remote_or_local(coordinator_host, canary_cmd, timeout=10.0)
    elif model:
        clean_model = model.strip("/")
        model_identifier = clean_model
        code_m, out_m, _ = run_remote_or_local(
            coordinator_host,
            f"if [ -e '{src_path}/{clean_model}' ]; then echo '__EXISTS__'; else echo '__MISSING__'; fi",
            timeout=10.0,
        )
        if code_m != 0 or "__MISSING__" in out_m:
            print_error(f"Specified model '{model}' does not exist under '{src_path}' on Coordinator ({coordinator_host}).")
            raise typer.Exit(code=1)
        print_info(f"Target model subset: [{GOLD}]{clean_model}[/{GOLD}]")

    # Compute source payload size in bytes for line rate and throughput calculations
    target_sync_path = f"{src_path}/.canary_sync" if canary else (f"{src_path}/{clean_model}" if clean_model else src_path)
    size_cmd = f"if [ -e '{target_sync_path}' ]; then du -sb '{target_sync_path}' 2>/dev/null | cut -f1 || du -sk '{target_sync_path}' 2>/dev/null | awk '{{print $1*1024}}'; else echo 0; fi"
    _, out_sz, _ = run_remote_or_local(coordinator_host, size_cmd, timeout=10.0)
    try:
        size_bytes = int(out_sz.strip().splitlines()[-1])
    except Exception:
        size_bytes = 0

    def format_bytes(b: int) -> str:
        if b >= 1024 ** 3:
            return f"{b / (1024 ** 3):.2f} GB"
        elif b >= 1024 ** 2:
            return f"{b / (1024 ** 2):.2f} MB"
        elif b >= 1024:
            return f"{b / 1024:.2f} KB"
        elif b > 0:
            return f"{b} B"
        return "0 B"

    size_display = format_bytes(size_bytes) if size_bytes > 0 else src_size

    # 2. Query Kubernetes nodes
    res = run_kubectl(["get", "nodes", "-o", "json"], coordinator_host=coordinator_host)
    if res.returncode != 0:
        print_error(f"Failed to query Kubernetes nodes: {res.stderr.strip() or res.stdout.strip()}")
        raise typer.Exit(code=1)

    try:
        nodes_data = json.loads(res.stdout)
        items = nodes_data.get("items", [])
    except Exception as e:
        print_error(f"Failed to parse Kubernetes nodes output: {e}")
        raise typer.Exit(code=1)

    # Discover control plane node and filter target nodes
    cp_node_name: Optional[str] = None
    all_k8s_nodes: List[Dict[str, Any]] = []

    for item in items:
        n_name = item.get("metadata", {}).get("name", "")
        labels = item.get("metadata", {}).get("labels", {})
        is_cp = (
            "node-role.kubernetes.io/control-plane" in labels
            or "node-role.kubernetes.io/master" in labels
            or "control" in n_name.lower()
        )
        conditions = item.get("status", {}).get("conditions", [])
        is_ready = any(
            c.get("type") == "Ready" and c.get("status") == "True" for c in conditions
        )
        all_k8s_nodes.append({"name": n_name, "ready": is_ready, "is_cp": is_cp})
        if is_cp and is_ready and cp_node_name is None:
            cp_node_name = n_name

    specified_names = [n.lower() for n in node] if node else None
    target_k8s_nodes: List[Dict[str, Any]] = []

    for n_info in all_k8s_nodes:
        if specified_names is not None:
            if n_info["name"].lower() in specified_names:
                target_k8s_nodes.append(n_info)
        else:
            if not n_info["is_cp"]:
                target_k8s_nodes.append(n_info)

    if not target_k8s_nodes and not specified_names:
        target_k8s_nodes = [n for n in all_k8s_nodes if not n["is_cp"]]

    if not target_k8s_nodes:
        if specified_names:
            print_warning(f"No matching Kubernetes nodes found for: {', '.join(node)}")
        else:
            print_warning("No Kubernetes worker nodes found in cluster.")
        return

    print_info(f"Targeting {len(target_k8s_nodes)} node(s) for model synchronization...\n")

    synced_nodes: List[str] = []
    failed_nodes: List[str] = []
    hub_pod_name = "model-syncer-hub"
    hub_active = False
    hub_ip = "10.200.10.30"

    try:
        # Hierarchical Distribution Setup:
        # If control plane node is Ready, use it as the distribution hub
        if cp_node_name:
            # Resolve hub IP to control plane's native InternalIP (e.g. 10.200.10.211) so balance-alb bonding balances across both physical NICs
            for item in items:
                if item.get("metadata", {}).get("name") == cp_node_name:
                    for addr in item.get("status", {}).get("addresses", []):
                        if addr.get("type") == "InternalIP" and addr.get("address"):
                            hub_ip = addr.get("address")
                            break
            if not hub_ip:
                hub_ip = "10.200.10.30"

            console.print(f"  → Setting up Control Plane Hub on [{STEEL_BLUE}]{cp_node_name}[/{STEEL_BLUE}] (Pod: [{GOLD}]{hub_pod_name}[/{GOLD}], HostNetwork VIP: [{GOLD}]{hub_ip}[/{GOLD}])...")
            if deploy_staging_pod(kubectl_cmd, coordinator_host, hub_pod_name, cp_node_name, target_dir, is_hub=True):
                # Check if hub already has files populated
                if canary:
                    check_cmd = f"{kubectl_cmd} exec {hub_pod_name} --namespace kube-system -- sh -c 'test -f /models/.canary_sync && cat /models/.canary_sync'"
                elif clean_model:
                    check_cmd = f"{kubectl_cmd} exec {hub_pod_name} --namespace kube-system -- sh -c 'test -e /models/{shlex.quote(clean_model)} && echo __EXISTS__'"
                else:
                    check_cmd = f"{kubectl_cmd} exec {hub_pod_name} --namespace kube-system -- sh -c 'ls -A /models 2>/dev/null | head -n 1'"
                code_chk, out_chk, _ = run_remote_or_local(coordinator_host, check_cmd, timeout=15.0)
                hub_has_files = (code_chk == 0 and bool(out_chk.strip()))

                is_control_targeted = any(t["name"] == cp_node_name for t in target_k8s_nodes)
                if not hub_has_files or is_control_targeted:
                    t0 = time.time()
                    if canary:
                        console.print(f"    Streaming canary file from Coordinator [{STEEL_BLUE}]{src_path}/.canary_sync[/{STEEL_BLUE}] → Control Hub [{STEEL_BLUE}]{cp_node_name}:{target_dir}[/{STEEL_BLUE}]...")
                        stream_hub_cmd = f"rsync -av --inplace --whole-file {shlex.quote(src_path)}/.canary_sync rsync://{hub_ip}:8730/models/.canary_sync"
                        code_h, _, err_h = run_remote_or_local(coordinator_host, stream_hub_cmd, timeout=60.0)
                        if code_h != 0:
                            stream_hub_cmd = f"tar -C {shlex.quote(src_path)} -cf - .canary_sync | {kubectl_cmd} exec -i {hub_pod_name} --namespace kube-system -- tar -C /models -xf -"
                            code_h, _, err_h = run_remote_or_local(coordinator_host, stream_hub_cmd, timeout=60.0)
                    elif clean_model:
                        console.print(f"    Streaming model [{GOLD}]{clean_model}[/{GOLD}] from Coordinator [{STEEL_BLUE}]{src_path}[/{STEEL_BLUE}] → Control Hub [{STEEL_BLUE}]{cp_node_name}:{target_dir}[/{STEEL_BLUE}]...")
                        stream_hub_cmd = f"rsync -av --inplace --whole-file -R {shlex.quote(src_path)}/./{shlex.quote(clean_model)} rsync://{hub_ip}:8730/models/"
                        code_h, _, err_h = run_remote_or_local(coordinator_host, stream_hub_cmd, timeout=900.0)
                        if code_h != 0:
                            pdir = os.path.dirname(clean_model)
                            if pdir:
                                run_remote_or_local(coordinator_host, f"{kubectl_cmd} exec {hub_pod_name} --namespace kube-system -- mkdir -p /models/{shlex.quote(pdir)}", timeout=15.0)
                            stream_hub_cmd = f"tar -C {shlex.quote(src_path)} -cf - {shlex.quote(clean_model)} | {kubectl_cmd} exec -i {hub_pod_name} --namespace kube-system -- tar -C /models -xf -"
                            code_h, _, err_h = run_remote_or_local(coordinator_host, stream_hub_cmd, timeout=900.0)
                    else:
                        console.print(f"    Streaming models from Coordinator [{STEEL_BLUE}]{src_path}[/{STEEL_BLUE}] → Control Hub [{STEEL_BLUE}]{cp_node_name}:{target_dir}[/{STEEL_BLUE}]...")
                        rsync_hub_cmd = f"rsync -av --inplace --whole-file {shlex.quote(src_path.rstrip('/'))}/ rsync://{hub_ip}:8730/models/"
                        code_h, _, err_h = run_remote_or_local(coordinator_host, rsync_hub_cmd, timeout=900.0)
                        if code_h != 0:
                            rsync_hub_cmd = f"rsync -aP --inplace --whole-file -e \"{kubectl_cmd} exec -i\" {shlex.quote(src_path.rstrip('/'))}/ kube-system/{hub_pod_name}:/models/"
                            code_h, _, err_h = run_remote_or_local(coordinator_host, rsync_hub_cmd, timeout=900.0)
                            if code_h != 0:
                                stream_hub_cmd = f"tar -C {shlex.quote(src_path)} -cf - . | {kubectl_cmd} exec -i {hub_pod_name} --namespace kube-system -- tar -C /models -xf -"
                                code_h, _, err_h = run_remote_or_local(coordinator_host, stream_hub_cmd, timeout=900.0)
                    elapsed_h = time.time() - t0
                    if code_h == 0:
                        console.print(f"    [{SAGE_GREEN}][SUCCESS][/{SAGE_GREEN}] Populated hub on {cp_node_name} in {elapsed_h:.1f}s")
                        hub_active = True
                        if is_control_targeted and cp_node_name not in synced_nodes:
                            synced_nodes.append(cp_node_name)
                    else:
                        console.print(f"    [{CRIMSON}][FAIL][/{CRIMSON}] Failed to populate control hub: {err_h.strip()}")
                        if is_control_targeted and cp_node_name not in failed_nodes:
                            failed_nodes.append(cp_node_name)
                else:
                    console.print(f"    [{SAGE_GREEN}][READY][/{SAGE_GREEN}] Control plane hub [{GOLD}]{cp_node_name}[/{GOLD}] already populated.")
                    hub_active = True

                if hub_active:
                    console.print(f"    [{SAGE_GREEN}][DAEMON][/{SAGE_GREEN}] Started rsync:// daemon on [{GOLD}]{hub_ip}:8730[/{GOLD}] (hostNetwork bond)")
            else:
                console.print(f"    [{AMBER}][WARNING][/{AMBER}] Failed to deploy staging hub pod on {cp_node_name}. Falling back to direct streaming.")

        # Distribute to worker nodes in parallel
        worker_nodes_to_sync = [t for t in target_k8s_nodes if t["name"] != cp_node_name]
        ready_workers: List[Dict[str, Any]] = []
        for t_node in worker_nodes_to_sync:
            if not t_node["ready"]:
                console.print(f"  [{AMBER}][SKIP][/{AMBER}] Node [{STEEL_BLUE}]{t_node['name']}[/{STEEL_BLUE}] is NotReady in Kubernetes. Skipping.")
            else:
                ready_workers.append(t_node)

        def sync_worker_node(t_node: Dict[str, Any]) -> Dict[str, Any]:
            n_name = t_node["name"]
            pod_name = f"model-syncer-{n_name.lower().replace('.', '-')}"
            console.print(f"  → Synchronizing to worker node [{STEEL_BLUE}]{n_name}[/{STEEL_BLUE}] (Pod: [{GOLD}]{pod_name}[/{GOLD}])...")

            if not deploy_staging_pod(kubectl_cmd, coordinator_host, pod_name, n_name, target_dir, is_hub=False):
                console.print(f"    [{CRIMSON}][FAIL][/{CRIMSON}] Staging pod {pod_name} failed to become Ready.")
                return {
                    "node": n_name,
                    "success": False,
                    "duration": 0.0,
                    "err_msg": f"Staging pod {pod_name} failed to become Ready.",
                    "model": model_identifier,
                    "size_str": size_display,
                    "throughput_str": "0.0 MB/s (0.00 Gbps)",
                    "size_bytes": 0,
                }

            try:
                t0 = time.time()
                if hub_active and cp_node_name:
                    console.print(f"    Pulling via rsync:// from Hub [{STEEL_BLUE}]{hub_ip}:8730[/{STEEL_BLUE}] → [{STEEL_BLUE}]{n_name}:{target_dir}[/{STEEL_BLUE}]...")
                    if canary:
                        stream_cmd = f"{kubectl_cmd} exec {pod_name} --namespace kube-system -- rsync -av --inplace --whole-file rsync://{hub_ip}:8730/models/.canary_sync /models/"
                    elif clean_model:
                        stream_cmd = f"{kubectl_cmd} exec {pod_name} --namespace kube-system -- rsync -av --inplace --whole-file rsync://{hub_ip}:8730/models/{shlex.quote(clean_model)} /models/"
                    else:
                        stream_cmd = f"{kubectl_cmd} exec {pod_name} --namespace kube-system -- rsync -av --inplace --whole-file rsync://{hub_ip}:8730/models/ /models/"
                    stream_code, _, stream_err = run_remote_or_local(coordinator_host, stream_cmd, timeout=900.0)
                else:
                    console.print(f"    Streaming models from Coordinator [{STEEL_BLUE}]{src_path}[/{STEEL_BLUE}] → [{STEEL_BLUE}]{n_name}:{target_dir}[/{STEEL_BLUE}]...")
                    if canary:
                        stream_cmd = f"tar -C {shlex.quote(src_path)} -cf - .canary_sync | {kubectl_cmd} exec -i {pod_name} --namespace kube-system -- tar -C /models -xf -"
                        stream_code, _, stream_err = run_remote_or_local(coordinator_host, stream_cmd, timeout=60.0)
                    elif clean_model:
                        pdir = os.path.dirname(clean_model)
                        if pdir:
                            run_remote_or_local(coordinator_host, f"{kubectl_cmd} exec {pod_name} --namespace kube-system -- mkdir -p /models/{shlex.quote(pdir)}", timeout=15.0)
                        stream_cmd = f"tar -C {shlex.quote(src_path)} -cf - {shlex.quote(clean_model)} | {kubectl_cmd} exec -i {pod_name} --namespace kube-system -- tar -C /models -xf -"
                        stream_code, _, stream_err = run_remote_or_local(coordinator_host, stream_cmd, timeout=900.0)
                    else:
                        stream_cmd = f"rsync -aP --inplace --whole-file -e \"{kubectl_cmd} exec -i\" {shlex.quote(src_path.rstrip('/'))}/ kube-system/{pod_name}:/models/"
                        stream_code, _, stream_err = run_remote_or_local(coordinator_host, stream_cmd, timeout=900.0)
                        if stream_code != 0:
                            stream_cmd = f"tar -C {shlex.quote(src_path)} -cf - . | {kubectl_cmd} exec -i {pod_name} --namespace kube-system -- tar -C /models -xf -"
                            stream_code, _, stream_err = run_remote_or_local(coordinator_host, stream_cmd, timeout=900.0)

                elapsed = time.time() - t0
                if stream_code == 0:
                    if canary:
                        chk_code, chk_out, _ = run_remote_or_local(coordinator_host, f"{kubectl_cmd} exec {pod_name} --namespace kube-system -- sh -c 'test -f /models/.canary_sync && cat /models/.canary_sync'", timeout=15.0)
                        if chk_code != 0:
                            console.print(f"    [{CRIMSON}][FAIL][/{CRIMSON}] Canary file missing in {pod_name}")
                            return {
                                "node": n_name,
                                "success": False,
                                "duration": elapsed,
                                "err_msg": "Canary verification failed.",
                                "model": model_identifier,
                                "size_str": size_display,
                                "throughput_str": "0.0 MB/s (0.00 Gbps)",
                                "size_bytes": size_bytes,
                            }

                    if elapsed > 0 and size_bytes > 0:
                        mb_s = (size_bytes / (1024 * 1024)) / elapsed
                        gbps = (size_bytes * 8 / 1e9) / elapsed
                        tp_str = f"{mb_s:.1f} MB/s ({gbps:.2f} Gbps)"
                    else:
                        tp_str = "N/A"

                    console.print(f"    [{SAGE_GREEN}][SUCCESS][/{SAGE_GREEN}] Synchronized to {n_name} in {elapsed:.1f}s ({tp_str})")
                    return {
                        "node": n_name,
                        "success": True,
                        "duration": elapsed,
                        "err_msg": "",
                        "model": model_identifier,
                        "size_str": size_display,
                        "throughput_str": tp_str,
                        "size_bytes": size_bytes,
                    }
                else:
                    console.print(f"    [{CRIMSON}][FAIL][/{CRIMSON}] Stream failed for {n_name}: {stream_err.strip()}")
                    return {
                        "node": n_name,
                        "success": False,
                        "duration": elapsed,
                        "err_msg": stream_err.strip(),
                        "model": model_identifier,
                        "size_str": size_display,
                        "throughput_str": "0.0 MB/s (0.00 Gbps)",
                        "size_bytes": size_bytes,
                    }
            finally:
                run_remote_or_local(
                    coordinator_host,
                    f"{kubectl_cmd} delete pod {pod_name} --namespace kube-system --ignore-not-found=true --grace-period=0 --force 2>/dev/null",
                    timeout=15.0,
                )

        worker_results: List[Dict[str, Any]] = []
        if ready_workers:
            max_workers = min(len(ready_workers), 8)
            with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
                future_to_node = {
                    executor.submit(sync_worker_node, t_node): t_node["name"]
                    for t_node in ready_workers
                }
                for future in concurrent.futures.as_completed(future_to_node):
                    res_dict = future.result()
                    worker_results.append(res_dict)
                    if res_dict["success"]:
                        synced_nodes.append(res_dict["node"])
                    else:
                        failed_nodes.append(res_dict["node"])

        if worker_results:
            console.print()
            table = Table(
                title="AI Village Model Hub Concurrent Pull Performance",
                box=box.ROUNDED,
                header_style=f"bold {STEEL_BLUE}",
                border_style=MUTED_GREY,
                show_header=True,
            )
            table.add_column("Node Name", style=f"bold {GOLD}")
            table.add_column("Role", style=MUTED_GREY)
            table.add_column("Model Identifier", style=STEEL_BLUE)
            table.add_column("Size", justify="right")
            table.add_column("Duration (s)", justify="right")
            table.add_column("Individual Throughput", justify="right", style=f"bold {GOLD}")
            table.add_column("Status", justify="center")

            for r in worker_results:
                status_text = f"[{SAGE_GREEN}][SUCCESS][/{SAGE_GREEN}]" if r["success"] else f"[{CRIMSON}][FAIL][/{CRIMSON}]"
                table.add_row(
                    r["node"],
                    "Worker",
                    r["model"],
                    r["size_str"],
                    f"{r['duration']:.2f}s",
                    r["throughput_str"],
                    status_text,
                )
            console.print(table)

            successful_workers = [r for r in worker_results if r["success"]]
            if successful_workers and size_bytes > 0:
                max_elapsed = max(r["duration"] for r in successful_workers)
                total_bytes_transferred = len(successful_workers) * size_bytes
                if max_elapsed > 0:
                    agg_mb_s = (total_bytes_transferred / (1024 * 1024)) / max_elapsed
                    agg_gbps = (total_bytes_transferred * 8 / 1e9) / max_elapsed
                    console.print(f"\n[bold {GOLD}][METRIC] Aggregate Cluster Line Rate: {agg_gbps:.2f} Gbps ({agg_mb_s:.1f} MB/s across bond)[/bold {GOLD}]")

    finally:
        if cp_node_name:
            run_remote_or_local(
                coordinator_host,
                f"{kubectl_cmd} delete pod {hub_pod_name} --namespace kube-system --ignore-not-found=true --grace-period=0 --force 2>/dev/null",
                timeout=15.0,
            )

    # 8. Print summary
    console.print()
    if synced_nodes and not failed_nodes:
        print_success(f"Model synchronization complete: {len(synced_nodes)} node(s) synchronized ({', '.join(synced_nodes)}).")
    elif synced_nodes and failed_nodes:
        print_warning(f"Model synchronization partially succeeded: {len(synced_nodes)} synced ({', '.join(synced_nodes)}), {len(failed_nodes)} failed ({', '.join(failed_nodes)}).")
    else:
        print_error("Model synchronization failed for all target nodes.")
        raise typer.Exit(code=1)


# ── CLI Commands: Images Sub-typer ──────────────────────────────

def resolve_mirror(img: str, coord_host: str) -> str:
    """Resolves container mirror host and port on Coordinator."""
    if "ghcr.io" in img:
        port = 5002
    elif "registry.k8s.io" in img:
        port = 5003
    elif "quay.io" in img:
        port = 5004
    elif "gcr.io" in img:
        port = 5005
    else:
        port = 5001
    return f"{coord_host}:{port}"


@images_app.command(name="list")
def images_list_command() -> None:
    """Lists container images declared for workshops and cluster infrastructure."""
    print_header("AI Village Declared Container Images")
    coordinator_host = get_coordinator_host()

    table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    table.add_column("Category", style=f"bold {GOLD}")
    table.add_column("Image Reference", style=STEEL_BLUE)
    table.add_column("Mirror Endpoint", style=MUTED_GREY)

    for img in DEFAULT_WORKSHOP_IMAGES:
        mirror = resolve_mirror(img, coordinator_host)
        table.add_row("Workshop", img, mirror)

    for img in DEFAULT_INFRA_IMAGES:
        mirror = resolve_mirror(img, coordinator_host)
        table.add_row("Infrastructure", img, mirror)

    console.print(table)
    console.print()
    print_dim("Run `cluster cache images warmup` to pre-pull all images.\n")


@images_app.command(name="warmup")
def images_warmup_command(
    image_list: Optional[List[str]] = typer.Argument(None, help="Optional specific container images to pull"),
    all_images: bool = typer.Option(True, "--all", "-a", help="Warm up all default workshop and infrastructure images"),
    engine: Optional[str] = typer.Option(None, "--engine", "-e", help="Explicit container engine (docker/podman)"),
) -> None:
    """Warms container image mirrors by pulling images into local engine or coordinator mirror."""
    coordinator_host = get_coordinator_host()
    c_engine = engine or detect_container_engine(coordinator_host)

    if not c_engine:
        print_error("No container engine (docker/podman) found locally or on Coordinator.")
        raise typer.Exit(code=1)

    targets = list(image_list) if image_list else (DEFAULT_WORKSHOP_IMAGES + DEFAULT_INFRA_IMAGES)
    print_info(f"Using container engine: [{STEEL_BLUE}]{c_engine}[/{STEEL_BLUE}]")
    print_info(f"Pulling {len(targets)} container images to warm cache...\n")

    success_count = 0
    fail_count = 0

    for img in targets:
        console.print(f"  → Pulling [{STEEL_BLUE}]{img}[/{STEEL_BLUE}]...")
        pull_cmd = f"{c_engine} pull {shlex.quote(img)}"
        code, _, err = run_remote_or_local(coordinator_host, pull_cmd, timeout=120.0)
        if code == 0:
            console.print(f"    [{SAGE_GREEN}][OK][/{SAGE_GREEN}] Cached {img}")
            success_count += 1
        else:
            console.print(f"    [{AMBER}][WARN][/{AMBER}] Failed to pull {img}: {err.strip()[:100]}")
            fail_count += 1

    console.print()
    if fail_count == 0:
        print_success(f"Successfully warmed {success_count} container images.")
    else:
        print_warning(f"Warmed {success_count} images ({fail_count} failed or skipped).")


# ── CLI Commands: Models Sub-typer ──────────────────────────────

@models_app.command(name="list")
def models_list_command(
    path: str = typer.Option("/var/models", "--path", "-p", help="Target model directory path"),
    node: Optional[str] = typer.Option(None, "--node", "-n", help="Inspect specific cluster node"),
) -> None:
    """Lists AI models present in model storage across Coordinator and cluster nodes."""
    coordinator_host = get_coordinator_host()

    if node:
        print_header(f"Model Storage Inspection for Node: {node} ({path})")
        storage = inspect_model_storage(node, path)
        if not storage["exists"]:
            print_error(f"Directory {path} does not exist or node {node} unreachable.")
            return

        table = Table(box=box.ROUNDED, header_style=f"bold {STEEL_BLUE}", border_style=MUTED_GREY)
        table.add_column("Model Directory", style=f"bold {GOLD}")
        table.add_column("Status", style=SAGE_GREEN)

        for m in storage["models"]:
            table.add_row(m, "Present")
        console.print(table)
        console.print(f"Total capacity: {storage['size']} | Used: {storage['used']} | Available: {storage['avail']}\n")
    else:
        print_header(f"Cluster Model Storage Inspection ({path})")
        cache_status_command(models_path=path)


@models_app.command(name="sync")
def models_sync_command(
    node: Optional[List[str]] = typer.Option(
        None, "--node", "-n", help="Target worker node name(s) (e.g. worker1)"
    ),
    source_dir: Optional[str] = typer.Option(
        None, "--source", "-s", help="Source model storage path on Coordinator"
    ),
    target_dir: str = typer.Option(
        "/var/models", "--target", "-t", help="Target model storage path on worker nodes"
    ),
    model: Optional[str] = typer.Option(
        None, "--model", "-m", help="Specific model subfolder or name to sync instead of full directory"
    ),
    canary: bool = typer.Option(
        False, "--canary", "-c", help="Sync a lightweight canary file to verify intra-cluster staging pod transfer without sending full model weights"
    ),
) -> None:
    """Synchronizes model weights across Coordinator and worker nodes via K8s staging pod."""
    cache_sync_command(node=node, source_dir=source_dir, target_dir=target_dir, model=model, canary=canary)


@models_app.command(name="pull")
def models_pull_command(
    repo: str = typer.Argument(..., help="Hugging Face repository name (e.g. google/gemma-4-31B-it)"),
    target_dir: str = typer.Option("/var/lib/models", "--target-dir", "-d", help="Base model storage directory on Coordinator"),
    token: Optional[str] = typer.Option(None, "--token", "-t", help="Hugging Face API token"),
    include: Optional[List[str]] = typer.Option(None, "--include", "-i", help="File pattern(s) to include"),
    exclude: Optional[List[str]] = typer.Option(None, "--exclude", "-e", help="File pattern(s) to exclude"),
    local_dir: Optional[str] = typer.Option(None, "--local-dir", "-l", help="Subdirectory name inside target_dir"),
) -> None:
    """Pulls AI model weights from Hugging Face into model storage."""
    coordinator_host = get_coordinator_host()
    sub_dir = local_dir if local_dir else repo
    dest_path = f"{target_dir.rstrip('/')}/{sub_dir}"

    print_header(f"Pulling Model Weights: {repo}")
    print_info(f"Destination: [{STEEL_BLUE}]{dest_path}[/{STEEL_BLUE}] on Coordinator ({coordinator_host})")

    # Build hf download command arguments
    hf_token = token or os.environ.get("HF_TOKEN", "")
    token_env = f"export HF_TOKEN={shlex.quote(hf_token)}; " if hf_token else ""

    args = [repo, "--local-dir", dest_path]
    if include:
        for pat in include:
            args.extend(["--include", pat])
    if exclude:
        for pat in exclude:
            args.extend(["--exclude", pat])

    cli_args_str = " ".join(shlex.quote(a) for a in args)
    download_script = f"""
    {token_env}
    mkdir -p "{dest_path}"
    if command -v hf >/dev/null 2>&1; then
        hf download {cli_args_str}
    elif command -v huggingface-cli >/dev/null 2>&1; then
        huggingface-cli download {cli_args_str}
    else
        python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='{repo}', local_dir='{dest_path}')"
    fi
    """

    print_info("Starting model download in background/subprocess...")
    code, out, err = run_remote_or_local(coordinator_host, download_script, timeout=600.0)
    if code == 0:
        print_success(f"Model '{repo}' downloaded successfully to {dest_path}")
    else:
        print_error(f"Failed to download model '{repo}': {err.strip() or out.strip()}")
        raise typer.Exit(code=1)


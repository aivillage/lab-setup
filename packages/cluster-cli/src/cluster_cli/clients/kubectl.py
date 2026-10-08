import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from cluster_cli.config import get_kubeconfig_path, get_talosconfig_path, is_local_host
from cluster_cli.views.console import print_error, print_warning


def run_kubectl(
    args: List[str], coordinator_host: str = ""
) -> subprocess.CompletedProcess:
    """Executes kubectl locally or over SSH via coordinator."""
    kc = get_kubeconfig_path()
    if not kc:
        tc = get_talosconfig_path()
        if tc and os.path.isfile(tc):
            user_kc = Path.home() / ".cluster" / "k8s" / "kubeconfig"
            try:
                user_kc.parent.mkdir(parents=True, exist_ok=True)
                res_kc = subprocess.run(
                    ["talosctl", "--talosconfig", tc, "kubeconfig", str(user_kc)],
                    capture_output=True,
                    text=True,
                    timeout=5,
                )
                if res_kc.returncode != 0:
                    print_warning(f"Failed to generate kubeconfig from talosctl: {res_kc.stderr.strip()}")
                elif user_kc.is_file():
                    kc = str(user_kc)
            except Exception as e:
                print_warning(f"Error creating kubeconfig directory or file: {e}")

    if kc and os.path.isfile(kc):
        try:
            return subprocess.run(
                ["kubectl", "--kubeconfig", kc] + [str(a) for a in args],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except Exception as e:
            err = f"kubectl local execution failed: {e}"
            print_error(err)
            return subprocess.CompletedProcess(args=args, returncode=1, stdout="", stderr=err)

    if coordinator_host and not is_local_host(coordinator_host):
        remote_cmd = (
            "kubectl --kubeconfig /var/lib/coordinator/k8s/kubeconfig "
            + " ".join(shlex.quote(str(a)) for a in args)
        )
        try:
            return subprocess.run(
                [
                    "ssh",
                    "-o",
                    "ConnectTimeout=4",
                    "-o",
                    "StrictHostKeyChecking=no",
                    f"admin@{coordinator_host}",
                    remote_cmd,
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except Exception as e:
            err = f"kubectl SSH execution failed ({coordinator_host}): {e}"
            print_error(err)
            return subprocess.CompletedProcess(args=args, returncode=1, stdout="", stderr=err)

    return subprocess.CompletedProcess(args=args, returncode=1, stdout="", stderr="kubeconfig not found")


def get_nodes_info(coordinator_host: str = "") -> Tuple[Dict[str, Any], Optional[str]]:
    """Queries live Kubernetes API for registered nodes, statuses, and runtime versions."""
    node_k8s_status: Dict[str, Any] = {}
    k8s_error_msg: Optional[str] = None
    try:
        res = run_kubectl(["get", "nodes", "-o", "json"], coordinator_host=coordinator_host)
        if res.returncode == 0:
            nodes_json = json.loads(res.stdout)
            items = nodes_json.get("items", [])
            for k_node in items:
                k_name = k_node.get("metadata", {}).get("name", "<unknown>")
                conditions = k_node.get("status", {}).get("conditions", [])
                status_str = "NotReady"
                for cond in conditions:
                    if cond.get("type") == "Ready":
                        status_str = "Ready" if cond.get("status") == "True" else "NotReady"
                        break
                info = k_node.get("status", {}).get("nodeInfo", {})
                kubelet_v = info.get("kubeletVersion", "<none>")
                runtime_v = info.get("containerRuntimeVersion", "<none>")
                ip_addr = ""
                for addr in k_node.get("status", {}).get("addresses", []):
                    if addr.get("type") == "InternalIP":
                        ip_addr = addr.get("address", "")
                        break
                capacity = k_node.get("status", {}).get("capacity", {})
                allocatable = k_node.get("status", {}).get("allocatable", {})
                capacity_gpu = capacity.get("nvidia.com/gpu", "0") if isinstance(capacity, dict) else "0"
                allocatable_gpu = allocatable.get("nvidia.com/gpu", "0") if isinstance(allocatable, dict) else "0"

                node_k8s_status[k_name] = {
                    "status": status_str,
                    "ip": ip_addr,
                    "kubelet_version": kubelet_v,
                    "runtime_version": runtime_v,
                    "capacity_gpu": capacity_gpu,
                    "allocatable_gpu": allocatable_gpu,
                }
        else:
            k8s_error_msg = (
                res.stderr.strip()
                if res.stderr
                else f"kubectl failed with exit code {res.returncode}"
            )
    except Exception as e:
        k8s_error_msg = f"Kubernetes API error: {e}"

    return node_k8s_status, k8s_error_msg

import json
import os
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def get_env_var(name: str, default: str = "") -> str:
    """Retrieves stripped environment variable value or fallback."""
    return os.environ.get(name, default).strip()


def get_coordinator_host() -> str:
    """Returns the configured coordinator hostname or IP."""
    return get_env_var("CLUSTER_COORDINATOR_HOST", "127.0.0.1") or "127.0.0.1"


def get_control_vip() -> str:
    """Returns the control plane Virtual IP address."""
    vip = get_env_var("CLUSTER_CONTROL_VIP", "")
    if not vip:
        vip = get_env_var("VIP_IP", "")
    return vip


def get_endpoint() -> str:
    """Returns the Kubernetes/Talos API endpoint."""
    endpoint = get_env_var("CLUSTER_ENDPOINT", "")
    if not endpoint:
        vip = get_control_vip()
        if vip:
            endpoint = f"https://{vip}:6443"
    return endpoint


def get_subnet_broadcast(vip_ip: str) -> str:
    """Derives standard IPv4 broadcast address from VIP or returns fallback."""
    if not vip_ip or "." not in vip_ip:
        return "255.255.255.255"
    octets = vip_ip.strip().split(".")
    if len(octets) == 4:
        return f"{octets[0]}.{octets[1]}.{octets[2]}.255"
    return "255.255.255.255"


def is_local_host(host: str) -> bool:
    """Checks whether the specified host represents the local machine."""
    if not host or host in ("127.0.0.1", "localhost", "::1", "0.0.0.0"):
        return True
    try:
        local_hostname = socket.gethostname()
        if host == local_hostname or host.split(".")[0] == local_hostname.split(".")[0]:
            return True
        for info in socket.getaddrinfo(local_hostname, None):
            if host == info[4][0]:
                return True
    except Exception:
        pass
    return False


def get_talosconfig_path() -> Optional[str]:
    """Resolves path to valid talosconfig file."""
    env_path = os.environ.get("TALOSCONFIG")
    if env_path and os.path.isfile(env_path):
        return env_path
    standard_paths = [
        "/var/lib/coordinator/talos/talosconfig",
        f"{os.getcwd()}/.cluster/talos/talosconfig",
    ]
    for p in standard_paths:
        if os.path.isfile(p):
            return p
    return None


def get_kubeconfig_path() -> Optional[str]:
    """Resolves path to valid kubeconfig file."""
    env_path = os.environ.get("KUBECONFIG")
    if env_path and os.path.isfile(env_path):
        return env_path
    standard_paths = [
        f"{os.getcwd()}/.cluster/kubeconfig",
        f"{os.getcwd()}/.cluster/k8s/kubeconfig",
        "/var/lib/coordinator/k8s/kubeconfig",
        "/var/lib/coordinator/talos/kubeconfig",
        str(Path.home() / ".cluster" / "k8s" / "kubeconfig"),
        str(Path.home() / ".kube" / "config"),
    ]
    for p in standard_paths:
        if os.path.isfile(p):
            return p
    return None


def get_machines_data() -> Dict[str, Any]:
    """Parses declared machines metadata from environment JSON."""
    raw_json = get_env_var("CLUSTER_MACHINES_JSON", "{}")
    try:
        res = json.loads(raw_json) if raw_json else {}
        if isinstance(res, dict) and res:
            return res
    except Exception:
        pass
    return {}


def is_pingable(ip: str, timeout_sec: int = 1, coordinator_host: str = "") -> bool:
    """Tests ICMP reachability for a target IP address."""
    if not ip or ip in ("-", "null"):
        return False
    if coordinator_host and not is_local_host(coordinator_host):
        cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=2",
            "-o",
            "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            f"ping -c 1 -W {timeout_sec} {ip}",
        ]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return res.returncode == 0

    cmd = ["ping", "-c", "1", "-W", str(timeout_sec), ip]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if res.returncode != 0 and sys.platform == "darwin":
        res = subprocess.run(
            ["ping", "-c", "1", "-t", str(timeout_sec), ip],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return res.returncode == 0

#!/usr/bin/env python3
"""
AI Village Cluster CLI
Unified operational management tool for Talos Linux bare-metal clusters.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

# ANSI Color Codes
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
CYAN = "\033[36m"
RESET = "\033[0m"


def get_env_var(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def get_machines_data() -> Dict[str, Any]:
    raw_json = get_env_var("CLUSTER_MACHINES_JSON", "{}")
    try:
        return json.loads(raw_json) if raw_json else {}
    except Exception:
        return {}


def get_coordinator_host() -> str:
    return get_env_var("CLUSTER_COORDINATOR_HOST", "127.0.0.1") or "127.0.0.1"


def get_control_vip() -> str:
    vip = get_env_var("CLUSTER_CONTROL_VIP", "")
    if not vip:
        vip = get_env_var("VIP_IP", "")
    return vip


def get_subnet_broadcast(vip_ip: str) -> str:
    if not vip_ip or "." not in vip_ip:
        return "255.255.255.255"
    octets = vip_ip.strip().split(".")
    if len(octets) == 4:
        return f"{octets[0]}.{octets[1]}.{octets[2]}.255"
    return "255.255.255.255"


def fetch_coordinator_status(coordinator_host: str) -> Dict[str, Any]:
    try:
        url = f"http://{coordinator_host}:8080/api/status"
        req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            if resp.status == 200:
                return json.loads(resp.read().decode("utf-8"))
    except Exception:
        pass
    return {}


def is_local_host(coordinator_host: str) -> bool:
    if coordinator_host in ("127.0.0.1", "localhost"):
        return True
    try:
        local_hostname = socket.gethostname()
        if coordinator_host == local_hostname:
            return True
    except Exception:
        pass
    return False


def is_pingable(ip: str, timeout_sec: int = 1, coordinator_host: str = "") -> bool:
    if not ip or ip == "-":
        return False
    if coordinator_host and not is_local_host(coordinator_host):
        cmd = ["ssh", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", f"ping -c 1 -W {timeout_sec} {ip}"]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return res.returncode == 0

    cmd = ["ping", "-c", "1", "-W", str(timeout_sec), ip]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if res.returncode != 0 and sys.platform == "darwin":
        res = subprocess.run(["ping", "-c", "1", "-t", str(timeout_sec), ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return res.returncode == 0


def run_talosctl(args: List[str], coordinator_host: str = "") -> subprocess.CompletedProcess:
    if coordinator_host and not is_local_host(coordinator_host):
        remote_cmd = "talosctl --talosconfig /var/lib/coordinator/talos/talosconfig " + " ".join(shlex.quote(str(a)) for a in args)
        return subprocess.run(["ssh", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", remote_cmd], capture_output=True, text=True, timeout=10)
    tc = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
    return subprocess.run(["talosctl", "--talosconfig", tc] + [str(a) for a in args], capture_output=True, text=True, timeout=10)


def run_kubectl(args: List[str], coordinator_host: str = "") -> subprocess.CompletedProcess:
    if coordinator_host and not is_local_host(coordinator_host):
        remote_cmd = "kubectl " + " ".join(shlex.quote(str(a)) for a in args)
        return subprocess.run(["ssh", "-o", "ConnectTimeout=4", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", remote_cmd], capture_output=True, text=True, timeout=10)
    kc = get_kubeconfig_path() or f"{os.getcwd()}/.cluster/k8s/kubeconfig"
    return subprocess.run(["kubectl", "--kubeconfig", kc] + [str(a) for a in args], capture_output=True, text=True, timeout=10)


def get_talosconfig_path() -> Optional[str]:
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
    env_path = os.environ.get("KUBECONFIG")
    if env_path and os.path.isfile(env_path):
        return env_path
    standard_paths = [
        "/var/lib/coordinator/talos/kubeconfig",
        f"{os.getcwd()}/.cluster/k8s/kubeconfig",
    ]
    for p in standard_paths:
        if os.path.isfile(p):
            return p
    return None


def send_wol_packet(mac_str: str, broadcast_ip: str = "255.255.255.255", port: int = 9) -> None:
    clean_mac = mac_str.replace(":", "").replace("-", "").strip()
    if len(clean_mac) != 12:
        raise ValueError(f"Invalid MAC address format: {mac_str}")
    mac_bytes = bytes.fromhex(clean_mac)
    magic_packet = b"\xff" * 6 + mac_bytes * 16
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic_packet, (broadcast_ip, port))


def merge_cluster_nodes(machines: dict, wipe_data: dict) -> list:
    """
    Merges Flake declared machines with Coordinator MAC-keyed wipe_data into a unified list.
    Returns list of dicts: [ { name, pxe_ip, primary_mac, all_macs, wipe, is_nvidia, role, is_declared } ]
    """
    nodes_by_name = {}

    # 1. Ingest declared machines
    for mname, mspec in (machines or {}).items():
        if not isinstance(mspec, dict):
            continue

        mmacs = list(mspec.get("macs", []))
        net_ifaces = mspec.get("networkInterfaces") or mspec.get("network-interfaces", {})
        primary_iface = mspec.get("iface", "-")
        pmac = ""

        if isinstance(net_ifaces, dict):
            for iname, icfg in net_ifaces.items():
                if isinstance(icfg, dict) and icfg.get("mac"):
                    mac_val = icfg["mac"]
                    if mac_val not in mmacs:
                        mmacs.append(mac_val)
                    if icfg.get("primary") or icfg.get("role") == "private":
                        pmac = mac_val
                        primary_iface = iname

        if not pmac and mmacs:
            pmac = mmacs[0]
        if not pmac:
            pmac = mspec.get("mac", "")

        nodes_by_name[mname] = {
            "name": mname,
            "role": "ControlPlane" if mspec.get("controlPlane") else "Worker",
            "nvidia": bool(mspec.get("nvidia")),
            "is_declared": True,
            "iface": primary_iface,
            "pxe_ip": mspec.get("ip", "-"),
            "primary_mac": pmac or "-",
            "macs": mmacs,
            "wipe": {"requested": False, "status": "NONE", "timestamp": None, "log": None}
        }

    # 2. Merge Coordinator wipe_data (keyed by MAC)
    for wmac, wentry in (wipe_data or {}).items():
        if wmac.startswith("wipe_") or not isinstance(wentry, dict):
            continue

        wname = wentry.get("name")
        w_macs = wentry.get("macs", [wmac])
        clean_wmac = wmac.replace(":", "").replace("-", "").lower()
        w_all_macs = [m.replace(":", "").replace("-", "").lower() for m in w_macs]

        # Try to match by name or by MACs
        matched_rec = None
        if wname and wname in nodes_by_name:
            matched_rec = nodes_by_name[wname]
        else:
            for rec in nodes_by_name.values():
                clean_pmac = rec.get("primary_mac", "").replace(":", "").replace("-", "").lower()
                rec_macs = [m.replace(":", "").replace("-", "").lower() for m in rec.get("macs", [])]
                if clean_wmac == clean_pmac or any(m in rec_macs for m in w_all_macs):
                    matched_rec = rec
                    break

        if matched_rec:
            if wentry.get("pxe_ip"):
                matched_rec["pxe_ip"] = wentry["pxe_ip"]
            if wentry.get("pxe_mac"):
                matched_rec["primary_mac"] = wentry["pxe_mac"]
            elif not matched_rec.get("primary_mac") or matched_rec["primary_mac"] == "-":
                matched_rec["primary_mac"] = wmac
            if wentry.get("wipe"):
                matched_rec["wipe"] = wentry["wipe"]
        else:
            node_key = wname or f"node-{clean_wmac[-6:]}"
            nodes_by_name[node_key] = {
                "name": node_key,
                "role": "Worker",
                "nvidia": False,
                "is_declared": wentry.get("known", False),
                "iface": "-",
                "pxe_ip": wentry.get("pxe_ip", "-"),
                "primary_mac": wentry.get("pxe_mac", wmac),
                "macs": w_macs,
                "wipe": wentry.get("wipe", {})
            }

    return sorted(nodes_by_name.values(), key=lambda x: (0 if x.get("role") == "ControlPlane" else 1, x.get("name", "")))


# ==============================================================================
# Subcommand Handlers
# ==============================================================================

def handle_status(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    status_data = fetch_coordinator_status(coordinator_host)
    machines = get_machines_data()
    vip_ip = get_env_var("VIP_IP", "")
    wipe_data = (status_data or {}).get("wipe_data", {})
    nodes = merge_cluster_nodes(machines, wipe_data)
    nodes_by_name = {n["name"]: n for n in nodes if n.get("name")}

    # 1. Coordinator Health
    print(f"\n{BOLD}Coordinator System & Discovery State{RESET} {DIM}(http://{coordinator_host}:8080){RESET}")
    if status_data:
        print(f"  Service Status         : {GREEN}[HEALTHY] Online & Serving TFTP/iPXE/HTTP{RESET}")
        print(f"  DNS & TFTP Server IP   : {CYAN}{status_data.get('dns_ip', 'Unknown')}{RESET}")
        flake_nodes = status_data.get("flake_machines", [])
        if flake_nodes:
            print(f"  Registered Flake Nodes : {', '.join(flake_nodes)}")
        else:
            print(f"  Registered Flake Nodes : {YELLOW}(None registered){RESET}")
    else:
        print(f"  {RED}Unable to reach Coordinator server at {coordinator_host}:8080{RESET}")
    print()

    # 2. Control Plane & ETCD State
    print(f"{BOLD}Control Plane Bootstrap & ETCD State{RESET}")
    control_node_name = ""
    for name, data in machines.items():
        m_cfg = data.get("machine", {}) if isinstance(data.get("machine"), dict) else data
        if m_cfg.get("controlPlane") is True or data.get("controlPlane") is True:
            control_node_name = name
            break

    control_plane_ip = ""
    try:
        res = run_kubectl(["get", "node", control_node_name, "-o", "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}"], coordinator_host=coordinator_host)
        if res.returncode == 0 and res.stdout.strip():
            control_plane_ip = res.stdout.strip()
    except Exception:
        pass

    if not control_plane_ip and vip_ip and is_pingable(vip_ip, coordinator_host=coordinator_host):
        control_plane_ip = vip_ip

    if not control_plane_ip and control_node_name in nodes_by_name:
        c_node = nodes_by_name[control_node_name]
        candidate_ip = c_node.get("pxe_ip")
        if candidate_ip and candidate_ip != "-" and is_pingable(candidate_ip, coordinator_host=coordinator_host):
            control_plane_ip = candidate_ip

    if not control_plane_ip and vip_ip:
        control_plane_ip = vip_ip

    if not control_plane_ip:
        print(f"  Status : {YELLOW}[OFFLINE] No control plane registered (None defined in machines.nix){RESET}\n")
    else:
        is_bootstrapped = False
        try:
            res = run_talosctl(["etcd", "members", "--endpoints", control_plane_ip, "--nodes", control_plane_ip], coordinator_host=coordinator_host)
            if res.returncode == 0 and ("https://" in res.stdout or "control" in res.stdout):
                is_bootstrapped = True
        except Exception:
            pass

        if is_bootstrapped:
            print(f"  Status : {GREEN}[HEALTHY] Bootstrapped & Healthy{RESET}")
        else:
            if not is_pingable(control_plane_ip, coordinator_host=coordinator_host):
                print(f"  Status : {RED}[OFFLINE] Control plane node {control_node_name} [{control_plane_ip}] unreachable{RESET}")
            else:
                tc_path = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
                print(f"  Status : {YELLOW}[NOT BOOTSTRAPPED] Control plane is not initialized yet{RESET}")
                print(f"  {YELLOW}Bootstrap command:{RESET}")
                print(f"     {BOLD}talosctl --talosconfig {tc_path} --endpoints '{control_plane_ip}' --nodes '{control_plane_ip}' bootstrap{RESET}")
    print()

    # 3. Bare-Metal Nodes & Wipe State
    print(f"{BOLD}Bare-Metal Node Registration & Wipe State{RESET}")
    merged = merge_cluster_nodes(machines, wipe_data)
    if merged:
        print(f"  {BOLD}{'NODE':<14} {'PXE IP':<16} {'MAC':<18} {'WIPE STATE':<14} {'LAST RESULT':<14} {'LAST WIPED'}{RESET}")
        for node in merged:
            name = node["name"]
            pxe_ip = node["pxe_ip"] or "-"
            mac_str = node["primary_mac"] or "-"

            wipe_info = node.get("wipe", {})
            is_req = wipe_info.get("requested", False)
            last_status = wipe_info.get("status", "NONE")
            last_ts = wipe_info.get("timestamp") or "-"
            if last_ts != "-" and "T" in last_ts:
                last_ts = last_ts.replace("T", " ").split(".")[0]

            if last_status == "IN_PROGRESS":
                state_text = "IN_PROGRESS"
                state_color = YELLOW
            elif is_req:
                state_text = "PENDING"
                state_color = YELLOW
            elif last_status == "SHUTDOWN":
                state_text = "SHUTDOWN"
                state_color = DIM
            else:
                state_text = "READY"
                state_color = GREEN
            state_col = f"{state_color}{state_text:<14}{RESET}"

            if last_status == "SUCCESS":
                result_text = "SUCCESS"
                result_color = GREEN
            elif last_status == "FAILED":
                result_text = "FAILED"
                result_color = RED
            elif last_status == "IN_PROGRESS":
                result_text = "RUNNING"
                result_color = YELLOW
            elif last_status == "SHUTDOWN":
                result_text = "SHUTDOWN"
                result_color = DIM
            else:
                result_text = "-"
                result_color = DIM
            result_col = f"{result_color}{result_text:<14}{RESET}"

            node_col = f"{BOLD}{name:<14}{RESET}"
            pxe_col = f"{pxe_ip:<16}"
            mac_col = f"{mac_str:<18}"
            ts_col = f"{DIM if last_ts == '-' else ''}{last_ts}{RESET}"

            print(f"  {node_col} {pxe_col} {mac_col} {state_col} {result_col} {ts_col}")
    else:
        print(f"  {DIM}(No registered node records found){RESET}")
    print()

    # 4. Kubernetes Nodes Overview
    print(f"{BOLD}● Kubernetes Cluster Nodes{RESET}")
    node_k8s_status = {}
    try:
        res = run_kubectl(["get", "nodes", "-o", "json"], coordinator_host=coordinator_host)
        if res.returncode == 0:
            nodes_json = json.loads(res.stdout)
            items = nodes_json.get("items", [])
            if items:
                print(f"  {BOLD}{'NAME':<20} {'STATUS':<15} {'VERSION':<15} {'RUNTIME'}{RESET}")
                for node in items:
                    name = node.get("metadata", {}).get("name", "<unknown>")
                    conditions = node.get("status", {}).get("conditions", [])
                    status_str = "NotReady"
                    for cond in conditions:
                        if cond.get("type") == "Ready":
                            status_str = "Ready" if cond.get("status") == "True" else "NotReady"
                            break
                    info = node.get("status", {}).get("nodeInfo", {})
                    kubelet_v = info.get("kubeletVersion", "<none>")
                    runtime_v = info.get("containerRuntimeVersion", "<none>")
                    ip_addr = ""
                    for addr in node.get("status", {}).get("addresses", []):
                        if addr.get("type") == "InternalIP":
                            ip_addr = addr.get("address", "")
                            break
                    node_k8s_status[name] = {"status": status_str, "ip": ip_addr}
                    print(f"  {name:<20} {status_str:<15} {kubelet_v:<15} {runtime_v}")
            else:
                print(f"  {DIM}(No registered nodes returned by Kubernetes API){RESET}")
        else:
            print(f"  {DIM}(Kubernetes API server starting up...){RESET}")
    except Exception:
        print(f"  {DIM}(Kubernetes API server starting up...){RESET}")
    print()

    # 4. NVIDIA GPU Hardware & Drivers
    print(f"{BOLD}● NVIDIA GPU Hardware & Drivers{RESET}")
    gpu_nodes = [name for name, data in machines.items() if data.get("nvidia") or not data.get("controlPlane")]
    if not gpu_nodes:
        print(f"  {DIM}(No registered GPU/worker nodes in machines.nix){RESET}")
    else:
        for node_name in gpu_nodes:
            node_ip = machines.get(node_name, {}).get("ip")
            if not node_ip and node_name in node_k8s_status:
                node_ip = node_k8s_status[node_name].get("ip")
            if not node_ip and node_name in nodes_by_name:
                node_ip = nodes_by_name[node_name].get("pxe_ip")
            if not node_ip:
                for wmac, wentry in wipe_data.items():
                    if isinstance(wentry, dict) and (wentry.get("name") == node_name or wmac == node_name):
                        node_ip = wentry.get("pxe_ip")
                        break
            node_ip = node_ip or node_name
            is_nvidia = machines.get(node_name, {}).get("nvidia", False)
            online = (node_name in node_k8s_status and node_k8s_status[node_name]["status"] == "Ready") or (node_ip and is_pingable(node_ip, coordinator_host=coordinator_host))

            print(f"  {BOLD}{node_name}{RESET} ({node_ip}):")
            nvidia_flag = f"{GREEN}YES{RESET} (nvidia = true in machines.nix)" if is_nvidia else f"{YELLOW}NO{RESET} (nvidia = false in machines.nix)"
            status_flag = f"{GREEN}ONLINE (Ready){RESET}" if online else f"{RED}OFFLINE (Unreachable){RESET}"
            print(f"    NVIDIA Flag    : {nvidia_flag}")
            print(f"    Status         : {status_flag}")
    print()

    # 5. Config File Summary
    print(f"{BOLD}Configuration File Locations{RESET}")
    print(f"  talosconfig  : {CYAN}{get_talosconfig_path() or '/var/lib/coordinator/talos/talosconfig'}{RESET}")
    print(f"  kubeconfig   : {CYAN}{get_kubeconfig_path() or '/var/lib/coordinator/talos/kubeconfig'}{RESET}")
    print(f"  HTTP Configs : {CYAN}http://{coordinator_host}:8080/configs/<hostname>.yaml{RESET}")
    print(f"  Discovered   : {CYAN}http://{coordinator_host}:8080/api/discovered/machines.nix{RESET}\n")

    return 0


def handle_wakeup(args: argparse.Namespace) -> int:
    target = args.target
    coordinator_host = get_coordinator_host()
    vip_ip = get_control_vip()
    broadcast_ip = get_subnet_broadcast(vip_ip)
    machines = get_machines_data()
    status_data = fetch_coordinator_status(coordinator_host)
    local = is_local_host(coordinator_host)

    macs_to_wake = []

    if target in ("all", "cluster"):
        for name, data in machines.items():
            ifaces = data.get("networkInterfaces") or data.get("network-interfaces", {})
            for iface_info in ifaces.values():
                if isinstance(iface_info, dict) and iface_info.get("mac"):
                    macs_to_wake.append((name, iface_info["mac"]))
        if not macs_to_wake and status_data:
            wipe_data = status_data.get("wipe_data", {})
            for wmac, ninfo in wipe_data.items():
                if isinstance(ninfo, dict) and ninfo.get("macs"):
                    node_name = ninfo.get("name") or wmac
                    for m in ninfo["macs"]:
                        macs_to_wake.append((node_name, m))
    else:
        # Target specific node or MAC
        if target in machines:
            ifaces = machines[target].get("networkInterfaces") or machines[target].get("network-interfaces", {})
            for iface_info in ifaces.values():
                if isinstance(iface_info, dict) and iface_info.get("mac"):
                    macs_to_wake.append((target, iface_info["mac"]))
        elif status_data:
            wipe_data = status_data.get("wipe_data", {})
            for wmac, ninfo in wipe_data.items():
                if isinstance(ninfo, dict):
                    if ninfo.get("name") == target or wmac == target:
                        for m in ninfo.get("macs", [wmac]):
                            macs_to_wake.append((target, m))
                        break
        if not macs_to_wake:
            # Treat target as raw MAC
            macs_to_wake.append((target, target))

    if not macs_to_wake:
        print(f"{RED}Error: No MAC addresses found for target '{target}'{RESET}")
        return 1

    broadcast_ips = ["255.255.255.255"]
    if broadcast_ip:
        broadcast_ips.append(broadcast_ip)
    if status_data:
        priv_sub = status_data.get("private_subnet")
        pub_sub = status_data.get("public_subnet")
        if priv_sub and "/" in priv_sub:
            broadcast_ips.append(priv_sub.split("/")[0].rsplit(".", 1)[0] + ".255")
        if pub_sub and "/" in pub_sub:
            broadcast_ips.append(pub_sub.split("/")[0].rsplit(".", 1)[0] + ".255")
    broadcast_ips = list(set(broadcast_ips))

    print(f"\n{BOLD}Waking up {len(macs_to_wake)} network interface(s)...{RESET}")
    for name, mac in macs_to_wake:
        display = f"{name} ({mac})" if name != mac else mac
        clean_mac = mac.replace(":", "").replace("-", "")
        print(f"  WOL magic packet -> {display}...")
        for bcast in broadcast_ips:
            if local:
                try:
                    send_wol_packet(mac, broadcast_ip=bcast)
                except Exception:
                    pass
            else:
                try:
                    send_wol_packet(mac, broadcast_ip=bcast)
                except Exception:
                    pass
                cmd = ["ssh", "-o", "ConnectTimeout=3", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}",
                       f"perl -e 'use Socket; $pkt=chr(255)x6 . pack(\"H*\", \"{clean_mac}\")x16; socket(S,PF_INET,SOCK_DGRAM,getprotobyname(\"udp\")); setsockopt(S,SOL_SOCKET,SO_BROADCAST,1); send(S,$pkt,0,sockaddr_in(9,inet_aton(\"{bcast}\"))); send(S,$pkt,0,sockaddr_in(7,inet_aton(\"{bcast}\")));'"]
                subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print(f"{GREEN}Wake-on-LAN signals sent successfully.{RESET}")
    return 0


def handle_shutdown(args: argparse.Namespace) -> int:
    target = args.target
    coordinator_host = get_coordinator_host()
    machines = get_machines_data()
    status_data = fetch_coordinator_status(coordinator_host)
    talosconfig = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"

    def resolve_node_ip(name: str) -> str:
        if name in machines and machines[name].get("ip"):
            return machines[name]["ip"]
        if name == "control" or (name in machines and machines[name].get("controlPlane")):
            return "10.200.10.30"
        if status_data:
            wipe_data = status_data.get("wipe_data", {})
            for wmac, wentry in wipe_data.items():
                if isinstance(wentry, dict):
                    if wentry.get("name") == name or wmac == name:
                        if wentry.get("pxe_ip"):
                            return wentry["pxe_ip"]
        return name

    def notify_shutdown(name: str):
        url = f"http://{coordinator_host}:8080/api/wipe"
        is_local = is_local_host(coordinator_host)
        payload = json.dumps({"target": name, "status": "SHUTDOWN", "requested": False})
        if is_local:
            try:
                req = urllib.request.Request(url, data=payload.encode("utf-8"), headers={"Content-Type": "application/json"})
                urllib.request.urlopen(req, timeout=3)
            except Exception:
                pass
        else:
            ssh_opts = ["ssh", "-A", f"admin@{coordinator_host}"]
            remote_cmd = f"curl -s -X POST -H 'Content-Type: application/json' -d '{payload}' http://127.0.0.1:8080/api/wipe"
            try:
                subprocess.run(ssh_opts + [remote_cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            except Exception:
                pass

    def is_node_alive(ip: str) -> bool:
        if not ip or ip == "null":
            return False
        if is_local_host(coordinator_host):
            return is_pingable(ip)
        cmd = ["ssh", "-o", "ConnectTimeout=2", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}",
               f"ping -c 1 -W 1 {ip}"]
        res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return res.returncode == 0

    def shutdown_single_node(name: str) -> bool:
        ip = resolve_node_ip(name)
        if not is_node_alive(ip):
            print(f"  {YELLOW}Node {name} ({ip}) is already offline.{RESET}")
            notify_shutdown(name)
            return True

        print(f"  {BOLD}{CYAN}Sending shutdown command to node {name} ({ip})...{RESET}")
        if not is_local_host(coordinator_host):
            cmd = ["ssh", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}",
                   f"talosctl --talosconfig /var/lib/coordinator/talos/talosconfig -n {ip} shutdown --force"]
        else:
            cmd = ["talosctl"]
            if os.path.isfile(talosconfig):
                cmd += ["--talosconfig", talosconfig]
            cmd += ["--endpoints", ip, "--nodes", ip, "shutdown", "--force"]

        res = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
        if res.returncode != 0:
            print(f"  {RED}[ERROR] Failed to send shutdown command to {name} ({ip}): {res.stderr.strip()}{RESET}")
            return False

        print(f"  Waiting for node {name} ({ip}) to power off", end="", flush=True)
        for _ in range(15):
            time.sleep(1)
            print(".", end="", flush=True)
            if not is_node_alive(ip):
                print(f"\n  {GREEN}[SUCCESS] Node {name} ({ip}) powered off successfully.{RESET}")
                notify_shutdown(name)
                return True
        print(f"\n  {YELLOW}[TIMEOUT] Node {name} ({ip}) is still responding to ping after 15s.{RESET}")
        return False

    workers = [name for name, data in machines.items() if not data.get("controlPlane")]
    control_nodes = [name for name, data in machines.items() if data.get("controlPlane")]
    if not control_nodes:
        control_nodes = ["control"]

    if target in ("all", "cluster"):
        print("Gracefully shutting down worker nodes first...")
        for w in workers:
            shutdown_single_node(w)
        print("Shutting down control plane node last...")
        for c in control_nodes:
            shutdown_single_node(c)
    else:
        shutdown_single_node(target)

    print("Cluster shutdown verification complete.")
    return 0


def handle_pull_secrets(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    target_dir = Path(args.target_dir)

    print(f"{BOLD}{CYAN}Fetching secrets & configs from Coordinator ({coordinator_host})...{RESET}")
    (target_dir / "talos").mkdir(parents=True, exist_ok=True)
    (target_dir / "k8s").mkdir(parents=True, exist_ok=True)

    # 1. talosconfig
    local_tc = Path("/var/lib/coordinator/talos/talosconfig")
    dest_tc = target_dir / "talos" / "talosconfig"
    if local_tc.is_file():
        print(f"  Copying local {local_tc}...")
        dest_tc.write_bytes(local_tc.read_bytes())
    else:
        print(f"  Pulling talosconfig over SSH from admin@{coordinator_host}...")
        cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", "cat /var/lib/coordinator/talos/talosconfig"]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode == 0 and res.stdout:
            dest_tc.write_bytes(res.stdout)
    if dest_tc.is_file():
        dest_tc.chmod(0o600)

    # 2. kubeconfig
    local_kc = Path("/var/lib/coordinator/talos/kubeconfig")
    dest_kc = target_dir / "k8s" / "kubeconfig"
    if local_kc.is_file():
        print(f"  Copying local {local_kc}...")
        dest_kc.write_bytes(local_kc.read_bytes())
    else:
        print(f"  Pulling kubeconfig over SSH from admin@{coordinator_host}...")
        cmd = ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", "cat /var/lib/coordinator/talos/kubeconfig"]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode == 0 and res.stdout:
            dest_kc.write_bytes(res.stdout)
    if dest_kc.is_file():
        dest_kc.chmod(0o600)

    print(f"{BOLD}{GREEN}[SUCCESS] Successfully synchronized secrets to {target_dir}/{RESET}")
    return 0


def handle_discover(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    url = f"http://{coordinator_host}:8080/api/discovered/machines.nix"
    print(f"{BOLD}{CYAN}Querying discovered hardware from Coordinator ({coordinator_host}:8080)...{RESET}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            content = resp.read().decode("utf-8")
            if args.write:
                out_path = Path("machines.nix")
                out_path.write_text(content)
                print(f"{GREEN}[SUCCESS] Successfully wrote discovered hardware specification to ./machines.nix{RESET}")
            else:
                print(f"\n{content}")
        return 0
    except Exception as e:
        print(f"{RED}[ERROR] Failed to fetch discovered hardware: {e}{RESET}")
        return 1


def handle_purge(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    url = f"http://{coordinator_host}:8080/api/purge"
    print(f"{BOLD}{CYAN}Purging coordinator reports, wipe logs, and state ({coordinator_host}:8080)...{RESET}")
    try:
        req = urllib.request.Request(url, method="POST", headers={"User-Agent": "cluster-cli/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            print(f"{GREEN}[SUCCESS] {data.get('message', 'Coordinator state cleared.')} (Items purged: {data.get('purged_items', 0)}){RESET}")
    except Exception:
        remote_cmd = "curl -s -X POST http://127.0.0.1:8080/api/purge"
        res = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=no", f"admin@{coordinator_host}", remote_cmd], capture_output=True, text=True)
        if res.returncode == 0:
            print(f"{GREEN}[SUCCESS] Coordinator state purged successfully.{RESET}")
        else:
            print(f"{RED}[ERROR] Failed to purge coordinator state.{RESET}")
            return 1

    if getattr(args, "local", True) or getattr(args, "all", True):
        if Path("machines.nix").exists():
            Path("machines.nix").unlink(missing_ok=True)
            print(f"{GREEN}[SUCCESS] Removed local machines.nix{RESET}")
        if Path(".cluster").exists():
            shutil.rmtree(".cluster", ignore_errors=True)
            print(f"{GREEN}[SUCCESS] Removed local .cluster state directory{RESET}")
    return 0


def handle_gen(args: argparse.Namespace) -> int:
    target = args.target
    if target == "talos":
        out_dir = args.out_dir or ".cluster/talos"
        cmd = ["talos-gen", out_dir] if shutil.which("talos-gen") else ["echo", f"Rendering Talos configs to {out_dir}"]
        return subprocess.run(cmd).returncode
    elif target == "k8s":
        out_dir = args.out_dir or ".cluster/k8s"
        cmd = ["k8s-gen", out_dir] if shutil.which("k8s-gen") else ["echo", f"Rendering K8s manifests to {out_dir}"]
        return subprocess.run(cmd).returncode
    elif target == "secrets":
        out_file = args.out_dir or "secrets/talos.yaml"
        cmd = ["cluster-gen-secrets", out_file] if shutil.which("cluster-gen-secrets") else ["echo", f"Generating secrets to {out_file}"]
        return subprocess.run(cmd).returncode
    else:
        print(f"{BOLD}{CYAN}Usage: cluster gen <talos|k8s|secrets> [out_dir/file]{RESET}")
        return 1


def handle_apply(args: argparse.Namespace) -> int:
    target = args.target
    if target == "talos":
        node = args.arg or "all"
        cmd = ["talos-apply", node] if shutil.which("talos-apply") else ["echo", f"Applying Talos config to {node}"]
        return subprocess.run(cmd).returncode
    elif target == "k8s":
        manifest_dir = args.arg or ".cluster/k8s/manifests"
        cmd = ["k8s-apply", manifest_dir] if shutil.which("k8s-apply") else ["kubectl", "apply", "-f", manifest_dir]
        return subprocess.run(cmd).returncode
    else:
        print(f"{BOLD}{CYAN}Usage: cluster apply <talos|k8s> [node/manifest_dir]{RESET}")
        return 1


def handle_show(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    target_type = getattr(args, "show_target", None)
    target_name = getattr(args, "target_name", "")

    if not target_type or target_type in ("help", "--help", "-h"):
        print(f"\n{BOLD}{BLUE}========================================================{RESET}")
        print(f"{BOLD}{BLUE}  AI VILLAGE CLUSTER SHOW - INSPECTION UTILITY{RESET}")
        print(f"{BOLD}{BLUE}========================================================{RESET}\n")
        print(f"{BOLD}Usage:{RESET} {CYAN}cluster show <target> [name]{RESET}\n")
        print(f"{BOLD}Available Targets:{RESET}")
        print(f"  {BOLD}machines{RESET}          → Show table of all declared and discovered machines")
        print(f"  {BOLD}config <node>{RESET}     → Show rendered Talos OS YAML config for <node> or talosconfig")
        print(f"  {BOLD}report [node]{RESET}     → Show hardware discovery YAML report from Inspector")
        print(f"  {BOLD}network{RESET}           → Show cluster network subnets, VIP, and routes")
        print(f"  {BOLD}wipe-log <node>{RESET}   → Show latest storage wipe log for <node>\n")
        print(f"{BOLD}Examples:{RESET}")
        print(f"  {CYAN}cluster show machines{RESET}")
        print(f"  {CYAN}cluster show config control{RESET}")
        print(f"  {CYAN}cluster show config talosconfig{RESET}")
        print(f"  {CYAN}cluster show report control{RESET}")
        print(f"  {CYAN}cluster show network{RESET}\n")
        return 0

    if target_type in ("machines", "nodes"):
        status_data = fetch_coordinator_status(coordinator_host)
        flake_specs = status_data.get("flake_specs", {})
        wipe_data = status_data.get("wipe_data", {})
        machines_data = get_machines_data()

        merged = merge_cluster_nodes(machines_data or flake_specs, wipe_data)
        print(f"\n{BOLD}Cluster Machine Specifications{RESET} {DIM}(http://{coordinator_host}:8080){RESET}")
        print(f"  {BOLD}{'NODE':<14} {'ROLE':<16} {'NVIDIA':<8} {'STATUS':<14} {'PRIMARY IF':<14} {'PXE IP':<16} {'MAC ADDRESSES'}{RESET}")

        for m in merged:
            node_col = f"{BOLD}{m['name']:<14}{RESET}"
            role_col = f"{m['role']:<16}"
            nvidia_text = "Yes" if m['nvidia'] else "No"
            nvidia_col = f"{GREEN if m['nvidia'] else ''}{nvidia_text:<8}{RESET}"
            status_text = "DECLARED" if m['is_declared'] else "DISCOVERED"
            status_col = f"{CYAN if m['is_declared'] else YELLOW}{status_text:<14}{RESET}"
            iface_col = f"{m['iface']:<14}"
            pxe_col = f"{m['pxe_ip']:<16}"
            mac_str = ", ".join(m.get("macs", [])) if m.get("macs") else m.get("primary_mac", "-")

            print(f"  {node_col} {role_col} {nvidia_col} {status_col} {iface_col} {pxe_col} {mac_str}")
        print()
        return 0

    elif target_type in ("config", "configs"):
        if not target_name:
            print(f"{RED}Error: Please specify node name or config file (e.g. cluster show config control){RESET}")
            return 1

        conf_file = target_name if target_name.endswith(".yaml") or target_name == "talosconfig" else f"{target_name}.yaml"
        url = f"http://{coordinator_host}:8080/configs/{conf_file}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(f"{BOLD}Rendered Talos Config for {target_name} ({url}):{RESET}\n")
                print(resp.read().decode("utf-8"))
            return 0
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print(f"{RED}Config '{conf_file}' not found on Coordinator at {url}{RESET}")
            else:
                print(f"{RED}Failed to fetch config '{conf_file}': {e}{RESET}")
            return 1
        except Exception as e:
            print(f"{RED}Failed to fetch config '{conf_file}': {e}{RESET}")
            return 1

    elif target_type in ("report", "reports"):
        if not target_name:
            url = f"http://{coordinator_host}:8080/api/reports"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    reports = data.get("reports", [])
                    print(f"\n{BOLD}Hardware Inspector Reports on Coordinator ({coordinator_host}:8080):{RESET}")
                    if not reports:
                        print(f"  {DIM}(No reports found on coordinator){RESET}\n")
                        return 0
                    for r in reports:
                        fn = r.get("filename")
                        sz = r.get("size_bytes", 0)
                        print(f"  - {CYAN}{fn}{RESET} ({sz} bytes)")
                    print(f"\n{DIM}Run `cluster show report <node>` to view a specific report.{RESET}\n")
                return 0
            except Exception as e:
                print(f"{RED}Failed to fetch report list: {e}{RESET}")
                return 1
        else:
            url = f"http://{coordinator_host}:8080/api/reports?node={target_name}"
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
                with urllib.request.urlopen(req, timeout=5) as resp:
                    print(f"{BOLD}Hardware Inspector Report for {target_name}:{RESET}\n")
                    print(resp.read().decode("utf-8"))
                return 0
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    print(f"{YELLOW}No hardware report found for node '{target_name}' on Coordinator.{RESET}")
                else:
                    print(f"{RED}Failed to fetch hardware report: {e}{RESET}")
                return 1
            except Exception as e:
                print(f"{RED}Failed to fetch hardware report: {e}{RESET}")
                return 1

    elif target_type in ("network", "net"):
        status_data = fetch_coordinator_status(coordinator_host)
        vip_ip = get_control_vip()
        endpoint = get_env_var("CLUSTER_ENDPOINT", "") or (f"https://{vip_ip}:6443" if vip_ip else "-")

        print(f"\n{BOLD}AI Village Cluster Network Architecture{RESET}")
        print(f"  Coordinator Host : {CYAN}{status_data.get('coordinator_host', coordinator_host)}{RESET}")
        print(f"  Coordinator IP   : {CYAN}{status_data.get('dns_ip') or get_coordinator_host()}{RESET}")
        print(f"  Gateway Router   : {CYAN}{status_data.get('gateway_ip', '-')}{RESET}")
        print(f"  Private Subnet   : {CYAN}{status_data.get('private_subnet', '-')}{RESET} (VLAN 10)")
        print(f"  Public Subnet    : {CYAN}{status_data.get('public_subnet', '-')}{RESET} (VLAN 20)")
        print(f"  Control VIP      : {CYAN}{vip_ip or '-'}{RESET}")
        print(f"  K8s API Endpoint : {CYAN}{endpoint}{RESET}\n")
        return 0

    elif target_type in ("wipe-log", "wipelog"):
        if not target_name:
            print(f"{RED}Error: Please specify node name (e.g. cluster show wipe-log control){RESET}")
            return 1
        return handle_wipe(argparse.Namespace(action="logs", target=target_name))

    elif target_type in ("discovered",):
        url = f"http://{coordinator_host}:8080/api/discovered"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                nodes = data.get("nodes", [])
                print(f"\n{BOLD}Discovered Bare-Metal Nodes on Coordinator ({coordinator_host}:8080):{RESET}")
                if not nodes:
                    print(f"  {DIM}(No discovered nodes reported yet){RESET}\n")
                    return 0
                print(f"  {BOLD}{'NODE':<16} {'ROLE':<16} {'NVIDIA':<8} {'MAC ADDRESSES'}{RESET}")
                for n in nodes:
                    role_str = "ControlPlane" if n.get("controlPlane") else "Worker"
                    nv_str = "Yes" if n.get("nvidia") else "No"
                    macs_str = ", ".join(n.get("macs", []))
                    print(f"  {BOLD}{n.get('name', '-'):<16}{RESET} {role_str:<16} {nv_str:<8} {macs_str}")
                print()
            return 0
        except Exception as e:
            print(f"{RED}Failed to fetch discovered nodes: {e}{RESET}")
            return 1

    else:
        print(f"{RED}Unknown show target '{target_type}'. Use `cluster show help` for options.{RESET}")
        return 1


def fetch_wipe_status(coordinator_host: str) -> dict:
    status = fetch_coordinator_status(coordinator_host)
    if status and isinstance(status.get("wipe_data"), dict):
        return status["wipe_data"]
    return {}


def send_wipe_request(coordinator_host: str, target: str, requested: bool) -> tuple[bool, str]:
    """Sends wipe request either locally (if on coordinator) or via SSH with agent forwarding."""
    is_local = coordinator_host in ("127.0.0.1", "localhost") or Path("/var/lib/tftpboot").exists()
    payload_str = json.dumps({"target": target, "requested": requested})

    if is_local:
        url = "http://127.0.0.1:8080/api/wipe"
        try:
            req = urllib.request.Request(
                url,
                data=payload_str.encode("utf-8"),
                headers={"Content-Type": "application/json", "User-Agent": "cluster-cli/1.0"},
                method="POST"
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return True, data.get("status", "success")
        except Exception as e:
            return False, str(e)
    else:
        ssh_opts = ["ssh", "-A", f"admin@{coordinator_host}"]
        remote_cmd = f"curl -s -X POST -H 'Content-Type: application/json' -d '{payload_str}' http://127.0.0.1:8080/api/wipe"
        try:
            res = subprocess.run(ssh_opts + [remote_cmd], capture_output=True, text=True, timeout=10)
            if res.returncode == 0:
                try:
                    data = json.loads(res.stdout)
                    if data.get("status") == "success":
                        return True, "success"
                    return False, data.get("message", res.stdout)
                except Exception:
                    return True, res.stdout.strip()
            return False, res.stderr.strip() or f"SSH exited with code {res.returncode}"
        except Exception as e:
            return False, str(e)


def handle_wipe(args: argparse.Namespace) -> int:
    coordinator_host = get_coordinator_host()
    action = getattr(args, "action", None) or "status"

    if action == "status":
        wipe_data = fetch_wipe_status(coordinator_host)
        machines = get_machines_data()
        print(f"{BOLD}Bare-Metal Node Registration & Wipe State{RESET} {DIM}(http://{coordinator_host}:8080){RESET}")
        merged = merge_cluster_nodes(machines, wipe_data)
        if not merged:
            print(f"  {DIM}(No registered nodes or wipe records found){RESET}\n")
            return 0

        print(f"  {BOLD}{'NODE':<14} {'PXE IP':<16} {'MAC':<18} {'WIPE STATE':<14} {'LAST RESULT':<14} {'LAST WIPED'}{RESET}")
        for node in merged:
            name = node["name"]
            pxe_ip = node["pxe_ip"] or "-"
            mac_str = node["primary_mac"] or "-"

            wipe_info = node.get("wipe", {})
            is_req = wipe_info.get("requested", False)
            last_status = wipe_info.get("status", "NONE")
            last_ts = wipe_info.get("timestamp") or "-"
            if last_ts != "-" and "T" in last_ts:
                last_ts = last_ts.replace("T", " ").split(".")[0]

            if last_status == "IN_PROGRESS":
                state_text = "IN_PROGRESS"
                state_color = YELLOW
            elif is_req:
                state_text = "PENDING"
                state_color = YELLOW
            elif last_status == "SHUTDOWN":
                state_text = "SHUTDOWN"
                state_color = DIM
            else:
                state_text = "READY"
                state_color = GREEN
            state_col = f"{state_color}{state_text:<14}{RESET}"

            if last_status == "SUCCESS":
                result_text = "SUCCESS"
                result_color = GREEN
            elif last_status == "FAILED":
                result_text = "FAILED"
                result_color = RED
            elif last_status == "IN_PROGRESS":
                result_text = "RUNNING"
                result_color = YELLOW
            elif last_status == "SHUTDOWN":
                result_text = "SHUTDOWN"
                result_color = DIM
            else:
                result_text = "-"
                result_color = DIM
            result_col = f"{result_color}{result_text:<14}{RESET}"

            node_col = f"{BOLD}{name:<14}{RESET}"
            pxe_col = f"{pxe_ip:<16}"
            mac_col = f"{mac_str:<18}"
            ts_col = f"{DIM if last_ts == '-' else ''}{last_ts}{RESET}"

            print(f"  {node_col} {pxe_col} {mac_col} {state_col} {result_col} {ts_col}")
        print()
        return 0

    elif action in ("request", "cancel"):
        target = getattr(args, "target", "all") or "all"
        requested = (action == "request")
        action_verb = "Requesting wipe for" if requested else "Canceling wipe request for"
        print(f"{BOLD}{CYAN}{action_verb} '{target}' via Coordinator ({coordinator_host})...{RESET}")
        ok, msg = send_wipe_request(coordinator_host, target, requested)
        if ok:
            if requested:
                print(f"{GREEN}[SUCCESS] Wipe marked as REQUESTED for '{target}'. Node will be wiped by Inspector on next netboot.{RESET}")
            else:
                print(f"{GREEN}[SUCCESS] Wipe request CANCELED for '{target}'. Node will boot normally into Talos OS.{RESET}")
            return 0
        else:
            print(f"{RED}[ERROR] Failed to update wipe state: {msg}{RESET}")
            return 1

    elif action == "logs":
        target = getattr(args, "target", "")
        if not target:
            print(f"{RED}Error: Please specify node name for wipe logs (e.g. cluster wipe logs worker1){RESET}")
            return 1
        url = f"http://{coordinator_host}:8080/api/wipelog?node={target}"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "cluster-cli/1.0"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(f"{BOLD}Last Wipe Log for {target}:{RESET}\n")
                print(resp.read().decode("utf-8"))
            return 0
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print(f"{YELLOW}No wipe logs found on Coordinator for node '{target}'.{RESET}")
            else:
                print(f"{RED}Failed to fetch wipe log: {e}{RESET}")
            return 1
        except Exception as e:
            print(f"{RED}Failed to fetch wipe log: {e}{RESET}")
            return 1

    else:
        print(f"{BOLD}{CYAN}Usage: cluster wipe <status|request|cancel|logs> [node|all]{RESET}")
        return 1


# ==============================================================================
# Main Dispatcher
# ==============================================================================

def print_main_help():
    print(f"\n{BOLD}{CYAN}AI Village Cluster CLI{RESET} - Unified Operational Tooling\n")
    print(f"{BOLD}Usage:{RESET} {CYAN}cluster <command> [arguments]{RESET}\n")
    print(f"{BOLD}Commands:{RESET}")
    print(f"  {BOLD}{'status':<26}{RESET} Inspect live registered nodes, K8s health & GPU status")
    print(f"  {BOLD}{'show <target> [node]':<26}{RESET} Inspect machines, rendered configs, reports, or network")
    print(f"  {BOLD}{'wakeup <all|node>':<26}{RESET} Wake up node(s) or entire cluster via Wake-on-LAN")
    print(f"  {BOLD}{'shutdown <all|node>':<26}{RESET} Gracefully shut down node(s) or entire cluster")
    print(f"  {BOLD}{'wipe <action> [node]':<26}{RESET} Inspect, request, or cancel bare-metal node disk wipes")
    print(f"  {BOLD}{'discover [-w]':<26}{RESET} Fetch auto-generated hardware specification from Coordinator")
    print(f"  {BOLD}{'pull-secrets [dir]':<26}{RESET} Fetch canonical secrets & talosconfig from Coordinator")
    print(f"  {BOLD}{'gen <talos|k8s|secrets>':<26}{RESET} Render Talos OS node configs, K8s manifests, or PKI secrets")
    print(f"  {BOLD}{'apply <talos|k8s>':<26}{RESET} Apply Talos node configuration or Kubernetes manifests\n")
    print(f"{BOLD}Quick Examples:{RESET}")
    print(f"  {CYAN}cluster status{RESET}")
    print(f"  {CYAN}cluster show machines{RESET}")
    print(f"  {CYAN}cluster show config control{RESET}")
    print(f"  {CYAN}cluster show report control{RESET}")
    print(f"  {CYAN}cluster show network{RESET}")
    print(f"  {CYAN}cluster wipe status{RESET}")
    print(f"  {CYAN}cluster wipe request all{RESET}")
    print(f"  {CYAN}cluster wipe cancel all{RESET}")
    print(f"  {CYAN}cluster wakeup all{RESET}")
    print(f"  {CYAN}cluster shutdown all{RESET}")
    print(f"  {CYAN}cluster discover -w{RESET}")
    print(f"  {CYAN}cluster pull-secrets{RESET}\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="cluster",
        description="AI Village Cluster CLI - Unified Operational Tooling",
        add_help=False,
    )
    subparsers = parser.add_subparsers(dest="command", help="Available subcommands")

    # status
    p_status = subparsers.add_parser("status", help="Inspect live registered nodes, K8s health & GPU status")
    p_status.set_defaults(func=handle_status)

    # wakeup
    p_wake = subparsers.add_parser("wakeup", help="Wake up node(s) or entire cluster via Wake-on-LAN")
    p_wake.add_argument("target", nargs="?", default="all", help="Target node name, MAC address, or 'all'")
    p_wake.set_defaults(func=handle_wakeup)

    # shutdown
    p_shut = subparsers.add_parser("shutdown", help="Gracefully shut down node(s) or entire cluster")
    p_shut.add_argument("target", nargs="?", default="all", help="Target node name or 'all'")
    p_shut.set_defaults(func=handle_shutdown)

    # wipe
    p_wipe = subparsers.add_parser("wipe", help="Inspect, request, or cancel bare-metal node disk wipes")
    wipe_sub = p_wipe.add_subparsers(dest="action", help="Wipe subcommands")
    
    p_w_status = wipe_sub.add_parser("status", help="Display bare-metal wipe states and timestamps")
    p_w_status.set_defaults(func=handle_wipe)

    p_w_req = wipe_sub.add_parser("request", help="Request disk wipe for target node(s) on next netboot")
    p_w_req.add_argument("target", nargs="?", default="all", help="Target node name or 'all'")
    p_w_req.set_defaults(func=handle_wipe)

    p_w_canc = wipe_sub.add_parser("cancel", help="Cancel pending disk wipe for target node(s)")
    p_w_canc.add_argument("target", nargs="?", default="all", help="Target node name or 'all'")
    p_w_canc.set_defaults(func=handle_wipe)

    p_w_logs = wipe_sub.add_parser("logs", help="Fetch last wipe log from Coordinator for a node")
    p_w_logs.add_argument("target", help="Target node name")
    p_w_logs.set_defaults(func=handle_wipe)

    p_wipe.set_defaults(func=handle_wipe)

    # pull-secrets
    p_pull = subparsers.add_parser("pull-secrets", help="Fetch canonical secrets & talosconfig from Coordinator")
    p_pull.add_argument("target_dir", nargs="?", default=".cluster", help="Destination directory (default: .cluster)")
    p_pull.set_defaults(func=handle_pull_secrets)

    # discover
    p_disc = subparsers.add_parser("discover", help="Fetch auto-generated hardware specification from Coordinator")
    p_disc.add_argument("-w", "--write", action="store_true", help="Write output directly to ./machines.nix")
    p_disc.set_defaults(func=handle_discover)

    # gen
    p_gen = subparsers.add_parser("gen", help="Render Talos OS node configs, K8s manifests, or PKI secrets")
    p_gen.add_argument("target", choices=["talos", "k8s", "secrets"], help="Target configuration type")
    p_gen.add_argument("out_dir", nargs="?", help="Output directory or target secrets file")
    p_gen.set_defaults(func=handle_gen)

    # apply
    p_app = subparsers.add_parser("apply", help="Apply Talos node configuration or Kubernetes manifests")
    p_app.add_argument("target", choices=["talos", "k8s"], help="Target configuration type")
    p_app.add_argument("arg", nargs="?", help="Target node name (for talos) or manifest directory (for k8s)")
    p_app.set_defaults(func=handle_apply)

    # show
    p_show = subparsers.add_parser("show", help="Inspect machines, rendered configs, hardware reports, or network")
    p_show.add_argument("show_target", nargs="?", default="help", choices=["machines", "config", "report", "network", "wipe-log", "discovered", "help"], help="Target artifact to inspect")
    p_show.add_argument("target_name", nargs="?", default="", help="Specific node name or configuration target")
    p_show.set_defaults(func=handle_show)

    # purge
    p_purge = subparsers.add_parser("purge", help="Purge all discovered hardware reports, wipe states, and local artifacts")
    p_purge.add_argument("--remote-only", dest="local", action="store_false", help="Only purge coordinator state, preserve local files")
    p_purge.set_defaults(func=handle_purge)

    # Parse args or display help
    if len(sys.argv) == 1 or sys.argv[1] in ("help", "--help", "-h"):
        print_main_help()
        return 0

    args = parser.parse_args()
    if hasattr(args, "func"):
        return args.func(args)
    else:
        print_main_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())

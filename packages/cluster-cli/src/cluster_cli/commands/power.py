import subprocess
import time
from typing import List, Tuple
import typer
from rich.table import Table
from rich import box

from cluster_cli.config import (
    get_coordinator_host,
    get_control_vip,
    get_subnet_broadcast,
    get_machines_data,
    is_local_host,
    is_pingable,
)
from cluster_cli.clients.coordinator import CoordinatorClient
from cluster_cli.clients.talosctl import shutdown_node
from cluster_cli.clients.kubectl import run_kubectl
from cluster_cli.utils.mac import normalize_mac, is_valid_mac
from cluster_cli.utils.wol import send_wol_packet
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
)
from cluster_cli.views.tables import merge_cluster_nodes


def wakeup_command(
    targets: List[str] = typer.Argument(None, help="Target node names, MAC addresses, or 'all'"),
) -> None:
    """Wake up node(s) or entire cluster via Wake-on-LAN magic packets."""
    if not targets:
        targets = ["all"]

    coordinator_host = get_coordinator_host()
    vip_ip = get_control_vip()
    broadcast_ip = get_subnet_broadcast(vip_ip)
    machines = get_machines_data()
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()
    discovered_nodes = status_data.get("discovered_nodes", [])
    wipe_data = status_data.get("wipe_data", {})
    local = is_local_host(coordinator_host)

    macs_to_wake: List[Tuple[str, str]] = []

    for target in targets:
        if target in ("all", "cluster"):
            for name, data in machines.items():
                ifaces = data.get("network-interfaces") or {}
                for iface_info in ifaces.values():
                    if isinstance(iface_info, dict) and iface_info.get("mac"):
                        macs_to_wake.append((name, iface_info["mac"]))
            if not macs_to_wake:
                for d in discovered_nodes:
                    dname = d.get("name", "discovered")
                    for m in d.get("macs", []):
                        macs_to_wake.append((dname, m))
                for wmac, ninfo in wipe_data.items():
                    if isinstance(ninfo, dict) and not wmac.startswith("wipe_"):
                        clean_w = normalize_mac(wmac)
                        if not any(clean_w == normalize_mac(m) for _, m in macs_to_wake):
                            macs_to_wake.append((wmac, wmac))
        else:
            if target in machines:
                ifaces = machines[target].get("network-interfaces") or {}
                for iface_info in ifaces.values():
                    if isinstance(iface_info, dict) and iface_info.get("mac"):
                        macs_to_wake.append((target, iface_info["mac"]))
            else:
                clean_tgt = normalize_mac(target)
                matched = False
                for d in discovered_nodes:
                    d_macs = d.get("macs", [])
                    clean_d_macs = [normalize_mac(m) for m in d_macs]
                    if d.get("name") == target or clean_tgt in clean_d_macs:
                        for m in d_macs:
                            macs_to_wake.append((d.get("name", target), m))
                        matched = True
                        break

                if not matched and status_data:
                    for wmac, ninfo in wipe_data.items():
                        if isinstance(ninfo, dict):
                            clean_w = normalize_mac(wmac)
                            if clean_w == clean_tgt or target == wmac:
                                macs_to_wake.append((target, wmac))
                                matched = True
                                break

                if not matched and clean_tgt:
                    if is_valid_mac(clean_tgt):
                        macs_to_wake.append((target, target))
                    else:
                        print_error(
                            f"Cannot wake up '{target}': Node is not registered in machines.nix or Coordinator, and '{target}' is not a valid MAC address."
                        )
                        console.print(f"  [{AMBER}]Hint: Wake by physical MAC: cluster wakeup <mac_address>[/{AMBER}]\n")

    if not macs_to_wake:
        print_error(f"No MAC addresses found for target(s): {', '.join(targets)}")
        return

    # Deduplicate while preserving order
    seen_macs_set = set()
    unique_macs: List[Tuple[str, str]] = []
    for name, mac in macs_to_wake:
        key = (name, normalize_mac(mac))
        if key not in seen_macs_set:
            seen_macs_set.add(key)
            unique_macs.append((name, mac))

    broadcast_ips = ["255.255.255.255", "10.200.10.255"]
    if broadcast_ip:
        broadcast_ips.append(broadcast_ip)
    if status_data:
        priv_sub = status_data.get("private_subnet")
        pub_sub = status_data.get("public_subnet")
        if priv_sub and "/" in priv_sub:
            broadcast_ips.append(priv_sub.split("/")[0].rsplit(".", 1)[0] + ".255")
        if pub_sub and "/" in pub_sub:
            broadcast_ips.append(pub_sub.split("/")[0].rsplit(".", 1)[0] + ".255")
    broadcast_ips = sorted(list(set(broadcast_ips)))

    valid_macs: List[Tuple[str, str, str]] = []
    for name, mac in unique_macs:
        clean_mac = normalize_mac(mac)
        if not is_valid_mac(clean_mac):
            print_error(f"Skipping invalid MAC: {mac}")
            continue
        valid_macs.append((name, mac, clean_mac))

    if not valid_macs:
        print_error("No valid MAC addresses to wake up.")
        return

    print_header(f"Waking up {len(valid_macs)} network interface(s)...")
    success_count = 0
    failed_transmissions: List[str] = []

    for name, mac, clean_mac in valid_macs:
        display = f"{name} ({mac})" if name != mac else mac
        console.print(f"  WOL magic packet -> [{STEEL_BLUE}]{display}[/{STEEL_BLUE}]...")
        for bcast in broadcast_ips:
            try:
                send_wol_packet(mac, broadcast_ip=bcast)
                success_count += 1
            except Exception as e:
                print_warning(f"Local WOL to {bcast} failed for {display}: {e}")
                failed_transmissions.append(f"{display} ({bcast})")

    if not local:
        macs_payload = [cm for _, _, cm in valid_macs]
        mac_args = " ".join(f'"{m}"' for m in macs_payload)
        perl_script = (
            'use Socket; '
            'for my $mac (@ARGV) { '
            '  my $clean = $mac; $clean =~ s/[:-]//g; '
            '  my $pkt = chr(255)x6 . pack("H*", $clean)x16; '
            '  socket(S, PF_INET, SOCK_DGRAM, getprotobyname("udp")); '
            '  setsockopt(S, SOL_SOCKET, SO_BROADCAST, 1); '
            '  for my $bcast ("10.200.10.255", "10.200.20.255", "255.255.255.255") { '
            '    send(S, $pkt, 0, sockaddr_in(9, inet_aton($bcast))); '
            '    send(S, $pkt, 0, sockaddr_in(7, inet_aton($bcast))); '
            '  } '
            '}'
        )
        cmd = [
            "ssh",
            "-A",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            f"perl -e '{perl_script}' {mac_args}",
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            print_error(f"Remote Wake-on-LAN failed via {coordinator_host}: {res.stderr.strip()}")
            failed_transmissions.append(f"Remote via {coordinator_host}")
        else:
            success_count += len(valid_macs)

    if success_count > 0:
        print_success("Wake-on-LAN signals sent successfully.")
        if failed_transmissions:
            print_warning(f"Failed transmissions: {', '.join(failed_transmissions)}")
    else:
        print_error("Failed to send Wake-on-LAN signals to any interface.")


def shutdown_command(
    targets: List[str] = typer.Argument(None, help="Target node names or 'all'"),
) -> None:
    """Gracefully shut down node(s) or entire cluster."""
    if not targets:
        targets = ["all"]

    coordinator_host = get_coordinator_host()
    machines = get_machines_data()
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()
    wipe_data = status_data.get("wipe_data", {}) if status_data else {}
    merged_nodes = merge_cluster_nodes(machines, wipe_data)
    nodes_by_name = {n["name"]: n for n in merged_nodes}

    def resolve_node_ip(name: str) -> str:
        if name in machines:
            net_ifaces = machines[name].get("network-interfaces") or {}
            for icfg in net_ifaces.values():
                if isinstance(icfg, dict) and icfg.get("ip"):
                    if icfg.get("primary") or icfg.get("role") == "private":
                        return icfg["ip"]
            for icfg in net_ifaces.values():
                if isinstance(icfg, dict) and icfg.get("ip"):
                    return icfg["ip"]
        if name in nodes_by_name and nodes_by_name[name].get("pxe_ip") and nodes_by_name[name]["pxe_ip"] != "-":
            return nodes_by_name[name]["pxe_ip"]
        if wipe_data:
            for wmac, wentry in wipe_data.items():
                if isinstance(wentry, dict) and (wentry.get("name") == name or wmac == name):
                    return wentry.get("pxe_ip", name)
        return name

    def is_node_alive(ip: str) -> bool:
        if not ip or ip in ("null", "-"):
            return False
        return is_pingable(ip, coordinator_host=coordinator_host)

    is_all = any(t in ("all", "cluster") for t in targets)
    all_workers = [name for name, data in machines.items() if not data.get("controlPlane")]
    all_control_nodes = [name for name, data in machines.items() if data.get("controlPlane")]
    if not all_control_nodes:
        all_control_nodes = ["control"]

    if is_all:
        target_workers = all_workers
        target_control = all_control_nodes
    else:
        target_workers = []
        target_control = []
        for t in targets:
            is_cp = False
            if t in machines:
                is_cp = bool(machines[t].get("controlPlane"))
            elif t in ("control", "cp", "master") or "control" in t:
                is_cp = True
            elif t in nodes_by_name:
                is_cp = bool(nodes_by_name[t].get("is_control_plane"))

            if is_cp:
                if t not in target_control:
                    target_control.append(t)
            else:
                if t not in target_workers:
                    target_workers.append(t)

    total_targets_count = len(target_workers) + len(target_control)
    if is_all or total_targets_count > 1:
        print_info("Attempting fast pod teardown in 'workshop' namespace...")
        try:
            res_delete = run_kubectl(
                ["delete", "pods", "--all", "-n", "workshop", "--grace-period=0", "--force", "--timeout=5s"],
                coordinator_host=coordinator_host,
            )
            if res_delete.returncode == 0:
                print_success("Workshop pods terminated cleanly.")
            else:
                err_msg = res_delete.stderr.strip()
                if "NotFound" in err_msg or not err_msg:
                    pass
                else:
                    print_warning(f"Workload teardown notice: {err_msg}")
        except Exception as e:
            print_warning(f"Non-blocking workload teardown skipped: {e}")

    results: List[Tuple[str, str, str, str, str]] = []

    def shutdown_single_node(name: str, role: str) -> bool:
        ip = resolve_node_ip(name)
        if not is_node_alive(ip):
            console.print(f"  [{AMBER}]Node {name} ({ip}) is already offline.[/{AMBER}]")
            results.append((name, ip, role, "Offline", "Already offline"))
            return True

        print_info(f"  Sending shutdown command to node {name} ({ip})...")
        res = shutdown_node(ip, coordinator_host=coordinator_host)

        if res.returncode != 0:
            err_msg = res.stderr.strip() or "Unknown error"
            print_error(f"Failed to send shutdown command to {name} ({ip}): {err_msg}")
            results.append((name, ip, role, "Failed", err_msg))
            return False

        console.print(f"  Waiting for node {name} ({ip}) to power off", end="")
        for _ in range(20):
            time.sleep(1)
            console.print(".", end="")
            if not is_node_alive(ip):
                console.print()
                print_success(f"Node {name} ({ip}) powered off successfully.")
                results.append((name, ip, role, "Powered Off", "Successfully stopped"))
                return True
        console.print()
        print_warning(f"Node {name} ({ip}) is still responding to ping after 20s.")
        results.append((name, ip, role, "Timed Out", "Still responding to ping after 20s"))
        return False

    if target_workers:
        print_info("Gracefully shutting down worker nodes first...")
        for w in target_workers:
            shutdown_single_node(w, "Worker")

    if target_control:
        print_info("Shutting down control plane node(s) last...")
        for c in target_control:
            shutdown_single_node(c, "Control Plane")

    table = Table(
        title="Cluster Shutdown Summary",
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
    )
    table.add_column("Node Name", style="bold", no_wrap=True)
    table.add_column("IP Address", style=MUTED_GREY)
    table.add_column("Role", style=GOLD)
    table.add_column("Status", justify="center")
    table.add_column("Details", style=MUTED_GREY)

    for name, ip, role, status, details in results:
        if status == "Powered Off":
            status_display = f"[{SAGE_GREEN}]Powered Off[/{SAGE_GREEN}]"
        elif status == "Offline":
            status_display = f"[{MUTED_GREY}]Offline[/{MUTED_GREY}]"
        elif status == "Failed":
            status_display = f"[{CRIMSON}]Failed[/{CRIMSON}]"
        else:
            status_display = f"[{AMBER}]{status}[/{AMBER}]"
        table.add_row(name, ip, role, status_display, details)

    console.print()
    console.print(table)
    console.print()
    print_success("Cluster shutdown verification complete.")

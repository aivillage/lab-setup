from typing import Any, Dict, List, Optional
from rich.table import Table
from rich import box

from cluster_cli.views.console import (
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    CRIMSON,
    AMBER,
)
from cluster_cli.utils.mac import normalize_mac


def merge_cluster_nodes(
    machines: Dict[str, Any],
    wipe_data: Dict[str, Any],
    discovered_nodes: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """
    Merges Flake declared machines with Coordinator MAC-keyed wipe_data and discovered_nodes.
    machines.nix is the sole authority on declared node names and membership.
    """
    nodes_by_name: Dict[str, Dict[str, Any]] = {}
    declared_macs = set()

    # 1. Ingest declared machines from Flake
    for mname, mspec in (machines or {}).items():
        if not isinstance(mspec, dict) or mname.startswith("_"):
            continue

        mmacs = list(mspec.get("macs", []))
        net_ifaces = mspec.get("network-interfaces") or {}
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

        clean_pmac = normalize_mac(pmac)
        clean_all_macs = [normalize_mac(m) for m in mmacs]
        declared_macs.update(clean_all_macs)

        matched_wentry = None
        for wmac, wentry in (wipe_data or {}).items():
            if not isinstance(wentry, dict) or wmac.startswith("wipe_"):
                continue
            clean_wmac = normalize_mac(wmac)
            if clean_wmac == clean_pmac or clean_wmac in clean_all_macs:
                matched_wentry = wentry
                break

        wspec = (
            matched_wentry.get("wipe", matched_wentry)
            if isinstance(matched_wentry, dict)
            else {}
        )
        is_req = bool(wspec.get("requested", False) or wspec.get("status") == "IN_PROGRESS")
        is_inst = (
            bool(matched_wentry.get("installed", False))
            if isinstance(matched_wentry, dict)
            else False
        )

        if is_req:
            boot_target = "Inspector (Wipe)"
        else:
            boot_target = "Talos"

        nodes_by_name[mname] = {
            "name": mname,
            "role": "ControlPlane" if mspec.get("controlPlane") else "Worker",
            "controlPlane": bool(mspec.get("controlPlane", False)),
            "nvidia": bool(mspec.get("nvidia")),
            "gpu_model": mspec.get("gpu_model") or mspec.get("gpu"),
            "is_declared": True,
            "known": True,
            "installed": is_inst,
            "boot_target": boot_target,
            "iface": primary_iface,
            "pxe_ip": (
                mspec.get("ip")
                or (matched_wentry.get("pxe_ip") if isinstance(matched_wentry, dict) else None)
                or "-"
            ),
            "primary_mac": pmac or "-",
            "macs": mmacs,
            "wipe": {
                "requested": bool(wspec.get("requested", False)),
                "status": wspec.get("status", "NONE"),
                "timestamp": wspec.get("timestamp"),
                "log": wspec.get("log"),
            },
        }

    # 2. Ingest discovered nodes from inspector reports
    for d in discovered_nodes or []:
        if not isinstance(d, dict):
            continue
        d_macs = d.get("macs", [])
        clean_d_macs = [normalize_mac(m) for m in d_macs]
        if any(m in declared_macs for m in clean_d_macs):
            continue

        d_name = d.get("name") or (
            f"node-{clean_d_macs[0][-6:]}" if clean_d_macs else "node-unknown"
        )
        primary_mac = d.get("primary_mac") or (d_macs[0] if d_macs else "-")
        clean_pmac = normalize_mac(primary_mac)
        declared_macs.update(clean_d_macs)

        matched_wentry = None
        for wmac, wentry in (wipe_data or {}).items():
            if not isinstance(wentry, dict) or wmac.startswith("wipe_"):
                continue
            clean_wmac = normalize_mac(wmac)
            if clean_wmac == clean_pmac:
                matched_wentry = wentry
                break
        if not matched_wentry:
            for wmac, wentry in (wipe_data or {}).items():
                if not isinstance(wentry, dict) or wmac.startswith("wipe_"):
                    continue
                clean_wmac = normalize_mac(wmac)
                if clean_wmac in clean_d_macs:
                    matched_wentry = wentry
                    break

        wspec = (
            matched_wentry.get("wipe", matched_wentry)
            if isinstance(matched_wentry, dict)
            else {}
        )
        is_req = bool(wspec.get("requested", False) or wspec.get("status") == "IN_PROGRESS")
        boot_target = "Inspector (Wipe)" if is_req else "Inspector (Discover)"

        disc_ip = d.get("pxe_ip")
        if not disc_ip or disc_ip == "-":
            disc_ip = (
                matched_wentry.get("pxe_ip") if isinstance(matched_wentry, dict) else None
            )

        nodes_by_name[d_name] = {
            "name": d_name,
            "role": "Worker",
            "controlPlane": False,
            "nvidia": bool(d.get("nvidia")),
            "gpu_model": d.get("gpu_model") or d.get("gpu"),
            "is_declared": False,
            "known": False,
            "installed": False,
            "boot_target": boot_target,
            "iface": d.get("iface", "-"),
            "pxe_ip": disc_ip or "-",
            "primary_mac": primary_mac,
            "macs": d_macs,
            "wipe": {
                "requested": bool(wspec.get("requested", False)),
                "status": wspec.get("status", "NONE"),
                "timestamp": wspec.get("timestamp"),
                "log": wspec.get("log"),
            },
        }

    # 3. Ingest any remaining undeclared / discovered MACs in wipe_data
    for wmac, wentry in (wipe_data or {}).items():
        if not isinstance(wentry, dict) or wmac.startswith("wipe_"):
            continue
        clean_wmac = normalize_mac(wmac)
        if clean_wmac in declared_macs:
            continue

        wspec = wentry.get("wipe", wentry) if isinstance(wentry, dict) else {}
        is_req = bool(wspec.get("requested", False) or wspec.get("status") == "IN_PROGRESS")
        mac_suffix = clean_wmac[-6:] if len(clean_wmac) >= 6 else "unknown"
        node_key = f"node-{mac_suffix}"
        boot_target = "Inspector (Wipe)" if is_req else "Inspector (Discover)"

        nodes_by_name[node_key] = {
            "name": node_key,
            "role": "Worker",
            "nvidia": False,
            "gpu_model": None,
            "is_declared": False,
            "known": False,
            "installed": False,
            "boot_target": boot_target,
            "iface": "-",
            "pxe_ip": wentry.get("pxe_ip", "-"),
            "primary_mac": wmac,
            "macs": [wmac],
            "wipe": {
                "requested": bool(wspec.get("requested", False)),
                "status": wspec.get("status", "NONE"),
                "timestamp": wspec.get("timestamp"),
                "log": wspec.get("log"),
            },
        }

    return sorted(
        nodes_by_name.values(),
        key=lambda x: (0 if x.get("role") == "ControlPlane" else 1, x.get("name", "")),
    )


def format_gpu_hardware(
    node: Dict[str, Any], reports_data: Optional[List[Dict[str, Any]]] = None
) -> str:
    """Formats GPU string based on node nvidia flag and inspector reports."""
    gpu_model = node.get("gpu_model") or node.get("gpu")
    has_nvidia = bool(node.get("nvidia"))

    if reports_data:
        node_name = node.get("name", "")
        clean_pmac = normalize_mac(node.get("primary_mac", ""))
        all_clean_macs = [normalize_mac(m) for m in node.get("macs", [])]
        for r in reports_data:
            if not isinstance(r, dict):
                continue
            fn = r.get("filename", "")
            clean_fn = fn.replace("inspector-report-", "").replace(".yaml", "").replace(":", "-").lower()
            matched = (
                (node_name and node_name.lower() in clean_fn)
                or (clean_pmac and clean_pmac in clean_fn.replace("-", ""))
                or any(cm and cm in clean_fn.replace("-", "") for cm in all_clean_macs)
            )
            if matched:
                if r.get("gpu_model"):
                    gpu_model = r["gpu_model"]
                if r.get("nvidia"):
                    has_nvidia = True
                break

    if gpu_model and isinstance(gpu_model, str):
        if "CDI" in gpu_model:
            return f"[{SAGE_GREEN}]{gpu_model}[/{SAGE_GREEN}]"
        return f"[{SAGE_GREEN}]{gpu_model} (CDI OK)[/{SAGE_GREEN}]"
    elif has_nvidia:
        return f"[{SAGE_GREEN}]NVIDIA Enabled[/{SAGE_GREEN}]"
    else:
        return f"[{MUTED_GREY}]None[/{MUTED_GREY}]"


def _extract_static_ip(mspec: Dict[str, Any]) -> str:
    """Extracts static IP from machine spec or network interface definitions."""
    if not isinstance(mspec, dict):
        return ""
    if mspec.get("ip"):
        return str(mspec["ip"])
    net_ifaces = mspec.get("network-interfaces") or {}
    if isinstance(net_ifaces, dict):
        for iname, icfg in net_ifaces.items():
            if isinstance(icfg, dict) and icfg.get("ip"):
                if icfg.get("primary") or icfg.get("role") == "private":
                    return str(icfg["ip"])
        for iname, icfg in net_ifaces.items():
            if isinstance(icfg, dict) and icfg.get("ip"):
                return str(icfg["ip"])
    if mspec.get("pxe_ip"):
        return str(mspec["pxe_ip"])
    return ""


def render_cluster_status_table(
    nodes: List[Dict[str, Any]], reports_data: Optional[List[Dict[str, Any]]] = None
) -> Table:
    """Renders Rich Table for bare-metal registration, GPU hardware, and wipe status."""
    table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    table.add_column("Node", style=f"bold {GOLD}")
    table.add_column("PXE Lease IP", style=STEEL_BLUE)
    table.add_column("Primary MAC", style=MUTED_GREY)
    table.add_column("GPU Hardware")
    table.add_column("Boot Target")
    table.add_column("Wipe On Boot")
    table.add_column("Last Result")
    table.add_column("Last Wiped", style=MUTED_GREY)

    for node in nodes:
        name = node["name"]
        pxe_ip = node.get("pxe_ip") or "-"
        mac_str = node.get("primary_mac") or "-"
        gpu_str = format_gpu_hardware(node, reports_data)

        wspec = node.get("wipe", {}) if isinstance(node.get("wipe"), dict) else {}
        is_req = wspec.get("requested", False)
        last_status = wspec.get("status", "NONE")
        last_ts = wspec.get("timestamp") or "-"
        if last_ts != "-" and "T" in last_ts:
            last_ts = last_ts.replace("T", " ").split(".")[0]

        if is_req or last_status == "IN_PROGRESS":
            boot_target = f"[{AMBER}]Inspector (Wipe)[/{AMBER}]"
        elif not node.get("known", False):
            boot_target = f"[{GOLD}]Inspector (Discover)[/{GOLD}]"
        else:
            boot_target = f"[{SAGE_GREEN}]Talos[/{SAGE_GREEN}]"

        if last_status == "IN_PROGRESS":
            wipe_on_boot = f"[{AMBER}]WIPING...[/{AMBER}]"
        elif is_req:
            wipe_on_boot = f"[{AMBER}]YES[/{AMBER}]"
        else:
            wipe_on_boot = f"[{SAGE_GREEN}]NO[/{SAGE_GREEN}]"

        if last_status == "SUCCESS":
            last_result = f"[{SAGE_GREEN}]SUCCESS[/{SAGE_GREEN}]"
        elif last_status == "FAILED":
            last_result = f"[{CRIMSON}]FAILED[/{CRIMSON}]"
        elif last_status == "IN_PROGRESS":
            last_result = f"[{AMBER}]RUNNING[/{AMBER}]"
        else:
            last_result = f"[{MUTED_GREY}]-[/{MUTED_GREY}]"

        table.add_row(
            name,
            pxe_ip,
            mac_str,
            gpu_str,
            boot_target,
            wipe_on_boot,
            last_result,
            last_ts,
        )

    return table


def render_wipe_status_table(nodes: List[Dict[str, Any]]) -> Table:
    """Renders Rich Table specifically for disk wipe management."""
    return render_cluster_status_table(nodes)


def render_k8s_nodes_table(
    machines: Dict[str, Any], k8s_nodes: Dict[str, Any]
) -> Table:
    """Renders Rich Table for active and declared Kubernetes cluster nodes."""
    table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    table.add_column("Node Name", style=f"bold {GOLD}")
    table.add_column("Role", style=STEEL_BLUE)
    table.add_column("Status")
    table.add_column("Static IP", style=STEEL_BLUE)
    table.add_column("GPU Allocations")
    table.add_column("Kubelet Version", style=MUTED_GREY)
    table.add_column("Container Runtime", style=MUTED_GREY)

    all_node_names = list(
        dict.fromkeys(
            list((machines or {}).keys()) + list((k8s_nodes or {}).keys())
        )
    )

    def sort_key(name: str):
        mspec = (machines or {}).get(name, {})
        is_cp = (
            mspec.get("controlPlane", False)
            if isinstance(mspec, dict)
            else False
        )
        return (0 if is_cp else 1, name)

    all_node_names.sort(key=sort_key)

    for name in all_node_names:
        if name.startswith("_"):
            continue
        mspec = (machines or {}).get(name, {}) if isinstance(machines, dict) else {}
        is_cp = bool(mspec.get("controlPlane", False)) if isinstance(mspec, dict) else False
        role_str = "ControlPlane" if is_cp else "Worker"

        if name in (k8s_nodes or {}):
            info = k8s_nodes[name]
            k_status = info.get("status", "NotReady")
            status_col = (
                f"[{SAGE_GREEN}][Ready][/{SAGE_GREEN}]"
                if k_status == "Ready"
                else f"[{CRIMSON}][NotReady][/{CRIMSON}]"
            )
            ip = info.get("ip") or _extract_static_ip(mspec) or "-"

            cap_gpu_str = str(info.get("capacity_gpu", "0"))
            alloc_gpu_str = str(info.get("allocatable_gpu", "0"))
            try:
                cap_int = int(cap_gpu_str)
                alloc_int = int(alloc_gpu_str)
                used_int = max(0, cap_int - alloc_int)
            except (ValueError, TypeError):
                cap_int = 0
                used_int = 0

            if cap_int > 0:
                gpu_alloc_str = f"[{SAGE_GREEN}]{used_int} / {cap_int}[/{SAGE_GREEN}]"
            elif isinstance(mspec, dict) and mspec.get("nvidia"):
                gpu_alloc_str = f"[{AMBER}]0 / 0 (Pending)[/{AMBER}]"
            else:
                gpu_alloc_str = f"[{MUTED_GREY}]-[/{MUTED_GREY}]"

            kubelet = info.get("kubelet_version", "<none>")
            runtime = info.get("runtime_version", "<none>")
        else:
            status_col = f"[{CRIMSON}][OFFLINE][/{CRIMSON}]"
            ip = _extract_static_ip(mspec) or "-"
            if isinstance(mspec, dict) and mspec.get("nvidia"):
                gpu_alloc_str = f"[{CRIMSON}]OFFLINE[/{CRIMSON}]"
            else:
                gpu_alloc_str = f"[{MUTED_GREY}]-[/{MUTED_GREY}]"
            kubelet = "-"
            runtime = "-"

        table.add_row(name, role_str, status_col, ip, gpu_alloc_str, kubelet, runtime)

    return table


def render_gpu_nodes_table(
    machines: Dict[str, Any],
    reports_data: Optional[List[Dict[str, Any]]] = None,
    discovered_nodes: Optional[List[Dict[str, Any]]] = None,
) -> Optional[Table]:
    """Renders Rich Table for physical GPU hardware presence and declarative CDI support."""
    table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    table.add_column("Node", style=f"bold {GOLD}")
    table.add_column("Physical GPU")
    table.add_column("machines.nix Support")
    table.add_column("Talos Runtime & CDI")

    disc_by_name: Dict[str, Dict[str, Any]] = {}
    disc_by_mac: Dict[str, Dict[str, Any]] = {}
    for d in discovered_nodes or []:
        if isinstance(d, dict):
            if d.get("name"):
                disc_by_name[d["name"]] = d
            for m in d.get("macs", []):
                disc_by_mac[normalize_mac(m)] = d

    rep_by_name: Dict[str, Dict[str, Any]] = {}
    for r in reports_data or []:
        if isinstance(r, dict):
            fn = r.get("filename", "")
            clean_fn = fn.replace("inspector-report-", "").replace(".yaml", "")
            rep_by_name[clean_fn] = r

    all_candidates = list(
        dict.fromkeys(
            list((machines or {}).keys())
            + list(disc_by_name.keys())
            + [d.get("name") for d in (discovered_nodes or []) if d.get("name")]
        )
    )

    rows_added = 0
    for name in sorted(all_candidates):
        if name.startswith("_"):
            continue
        mspec = (machines or {}).get(name, {}) if isinstance(machines, dict) else {}
        nvidia_support = (
            bool(mspec.get("nvidia", False)) if isinstance(mspec, dict) else False
        )

        has_physical_gpu = False
        d_entry = disc_by_name.get(name)
        if not d_entry and isinstance(mspec, dict):
            for m in mspec.get("macs", []):
                d_entry = disc_by_mac.get(normalize_mac(m))
                if d_entry:
                    break

        if d_entry and d_entry.get("nvidia"):
            has_physical_gpu = True

        if not has_physical_gpu:
            for rk, rinfo in rep_by_name.items():
                if name in rk or (
                    d_entry
                    and d_entry.get("primary_mac")
                    and normalize_mac(d_entry["primary_mac"]) in rk
                ):
                    if rinfo.get("nvidia"):
                        has_physical_gpu = True
                        break

        # Filter out nodes where both physical GPU is not detected and support is disabled
        if not has_physical_gpu and not nvidia_support:
            continue

        if has_physical_gpu and nvidia_support:
            phys_gpu_str = "YES (PCI NVIDIA GPU)"
            support_str = f"[{SAGE_GREEN}]ENABLED[/{SAGE_GREEN}]"
            runtime_str = "Active (nvidia.cdi.k8s.io / Talos GPU extensions)"
        elif has_physical_gpu and not nvidia_support:
            phys_gpu_str = "YES (PCI NVIDIA GPU)"
            support_str = f"[{AMBER}]DISABLED[/{AMBER}]"
            runtime_str = "Standard containerd (nvidia=false in config)"
        else:
            phys_gpu_str = "Pending / Not Detected"
            support_str = f"[{SAGE_GREEN}]ENABLED[/{SAGE_GREEN}]"
            runtime_str = "Configured in machines.nix"

        table.add_row(name, phys_gpu_str, support_str, runtime_str)
        rows_added += 1

    if rows_added == 0:
        return None
    return table


def render_machines_table(nodes: List[Dict[str, Any]]) -> Table:
    """Renders Rich Table for machine specifications inspection."""
    table = Table(
        box=box.ROUNDED,
        header_style=f"bold {STEEL_BLUE}",
        border_style=MUTED_GREY,
        show_header=True,
    )
    table.add_column("Node", style=f"bold {GOLD}")
    table.add_column("Role", style=STEEL_BLUE)
    table.add_column("NVIDIA")
    table.add_column("Status")
    table.add_column("Primary Interface", style=MUTED_GREY)
    table.add_column("PXE IP", style=STEEL_BLUE)
    table.add_column("MAC Addresses", style=MUTED_GREY)

    for m in nodes:
        name = m["name"]
        role = m["role"]
        nvidia_str = f"[{SAGE_GREEN}]Yes[/{SAGE_GREEN}]" if m["nvidia"] else "No"
        status_str = (
            f"[{STEEL_BLUE}]DECLARED[/{STEEL_BLUE}]"
            if m["is_declared"]
            else f"[{AMBER}]DISCOVERED[/{AMBER}]"
        )
        iface = m["iface"]
        pxe_ip = m["pxe_ip"]
        mac_str = ", ".join(m.get("macs", [])) if m.get("macs") else m.get("primary_mac", "-")
        table.add_row(name, role, nvidia_str, status_str, iface, pxe_ip, mac_str)

    return table

import json
from cluster_cli.config import (
    get_coordinator_host,
    get_machines_data,
    get_control_vip,
    get_talosconfig_path,
    get_kubeconfig_path,
    is_pingable,
)
from cluster_cli.clients.coordinator import CoordinatorClient
from cluster_cli.clients.talosctl import check_etcd_health
from cluster_cli.clients.kubectl import get_nodes_info, run_kubectl
from cluster_cli.views.console import (
    console,
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    CRIMSON,
    AMBER,
    print_header,
    print_dim,
)
from cluster_cli.views.tables import (
    merge_cluster_nodes,
    render_cluster_status_table,
    render_k8s_nodes_table,
)


def status_command() -> None:
    """Inspect live registered nodes, K8s workload health, and bare-metal provisioning state."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()

    machines = get_machines_data()
    if not machines and status_data and isinstance(status_data.get("flake_specs"), dict):
        machines = status_data["flake_specs"]

    vip_ip = get_control_vip()
    if not vip_ip and status_data:
        vip_ip = status_data.get("control_vip", "")

    wipe_data = (status_data or {}).get("wipe_data", {})
    discovered_nodes = (status_data or {}).get("discovered_nodes", [])

    reports_data = []
    code, rep_body = client.get_reports()
    if code == 200 and rep_body:
        try:
            reports_data = json.loads(rep_body).get("reports", [])
        except Exception:
            pass

    nodes = merge_cluster_nodes(machines, wipe_data, discovered_nodes)
    nodes_by_name = {n["name"]: n for n in nodes if n.get("name")}

    # Section 1: Compact 2-line Header
    if status_data:
        coord_status = f"[{SAGE_GREEN}][HEALTHY][/{SAGE_GREEN}] (http://{coordinator_host}:8080)"
    else:
        coord_status = f"[{CRIMSON}][OFFLINE][/{CRIMSON}] (http://{coordinator_host}:8080)"

    control_node_name = ""
    for name, data in (machines or {}).items():
        if not isinstance(data, dict) or name.startswith("_"):
            continue
        m_cfg = data.get("machine", {}) if isinstance(data.get("machine"), dict) else data
        if m_cfg.get("controlPlane") is True or data.get("controlPlane") is True:
            control_node_name = name
            break

    control_plane_ip = ""
    try:
        res = run_kubectl(
            [
                "get",
                "node",
                control_node_name or "control",
                "-o",
                "jsonpath={.status.addresses[?(@.type=='InternalIP')].address}",
            ],
            coordinator_host=coordinator_host,
        )
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

    is_bootstrapped = (
        check_etcd_health(control_plane_ip, coordinator_host=coordinator_host)
        if control_plane_ip
        else False
    )

    leader_tag = control_node_name or "control"
    if is_bootstrapped:
        etcd_status = f"[{SAGE_GREEN}][HEALTHY][/{SAGE_GREEN}] (Leader: {leader_tag})"
    elif control_plane_ip and is_pingable(control_plane_ip, coordinator_host=coordinator_host):
        etcd_status = f"[{AMBER}][NOT INITIALIZED][/{AMBER}] ({leader_tag})"
    else:
        etcd_status = f"[{CRIMSON}][OFFLINE][/{CRIMSON}] ({leader_tag})"

    coord_ip = (
        status_data.get("coordinator_ip")
        or status_data.get("dns_ip")
        or coordinator_host
    )
    flake_nodes = (
        status_data.get("flake_machines", [])
        if status_data and status_data.get("flake_machines")
        else [k for k in (machines or {}).keys() if not k.startswith("_")]
    )
    flake_nodes_str = ", ".join(flake_nodes) if flake_nodes else "(none)"

    console.print(f"Coordinator : {coord_status} | ETCD : {etcd_status}")
    console.print(
        f"Netboot / TFTP: [{STEEL_BLUE}]{coord_ip}[/{STEEL_BLUE}] | Flake Nodes : [{STEEL_BLUE}]{flake_nodes_str}[/{STEEL_BLUE}]"
    )
    console.print()

    # Section 2: Bare-Metal Hardware & Provisioning Tier
    print_header("Bare-Metal Hardware & Provisioning Tier")
    if nodes:
        console.print(render_cluster_status_table(nodes, reports_data))
    else:
        print_dim("(No registered node records found)")
    console.print()

    # Section 3: Kubernetes Workload Tier
    print_header("Kubernetes Workload Tier")
    k8s_nodes, _err = get_nodes_info(coordinator_host=coordinator_host)
    console.print(render_k8s_nodes_table(machines, k8s_nodes))
    console.print()

    # Section 4: Compact Configuration File Locations
    print_header("Configuration File Locations")
    talosconfig_path = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
    kubeconfig_path = get_kubeconfig_path() or "/var/lib/coordinator/talos/kubeconfig"
    console.print(f"  talosconfig  : [{STEEL_BLUE}]{talosconfig_path}[/{STEEL_BLUE}]")
    console.print(f"  kubeconfig   : [{STEEL_BLUE}]{kubeconfig_path}[/{STEEL_BLUE}]")
    console.print(
        f"  HTTP Configs : [{STEEL_BLUE}]http://{coordinator_host}:8080/configs/<hostname>.yaml[/{STEEL_BLUE}]\n"
    )

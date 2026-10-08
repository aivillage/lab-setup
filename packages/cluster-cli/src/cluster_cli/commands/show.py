import json
from typing import Optional
import typer

from cluster_cli.config import (
    get_coordinator_host,
    get_machines_data,
    get_control_vip,
    get_endpoint,
)
from cluster_cli.clients.coordinator import CoordinatorClient
from cluster_cli.views.console import (
    console,
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    CRIMSON,
    AMBER,
    print_header,
    print_error,
    print_warning,
    print_dim,
)
from cluster_cli.views.tables import merge_cluster_nodes, render_machines_table


def show_command(
    target: str = typer.Argument(
        "help",
        help="Target artifact: 'machines', 'config', 'report', 'network', or 'help'",
    ),
    name: Optional[str] = typer.Argument(
        None, help="Specific node name or configuration target"
    ),
) -> None:
    """Inspect machines, rendered configs, hardware reports, or network architecture."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if not target or target in ("help", "--help", "-h"):
        print_header("AI VILLAGE CLUSTER SHOW - INSPECTION UTILITY")
        console.print(f"[bold]Usage:[/bold] [{STEEL_BLUE}]cluster show <target> [name][/{STEEL_BLUE}]\n")
        console.print("[bold]Available Targets:[/bold]")
        console.print("  [bold]machines[/bold]          → Show table of all declared and discovered machines")
        console.print("  [bold]config <node>[/bold]     → Show rendered Talos OS YAML config for <node> or talosconfig")
        console.print("  [bold]report [node][/bold]     → Show hardware discovery YAML report from Inspector")
        console.print("  [bold]network[/bold]           → Show cluster network subnets, VIP, and routes\n")
        console.print("[bold]Examples:[/bold]")
        console.print(f"  [{STEEL_BLUE}]cluster show machines[/{STEEL_BLUE}]")
        console.print(f"  [{STEEL_BLUE}]cluster show config control[/{STEEL_BLUE}]")
        console.print(f"  [{STEEL_BLUE}]cluster show config talosconfig[/{STEEL_BLUE}]")
        console.print(f"  [{STEEL_BLUE}]cluster show report control[/{STEEL_BLUE}]")
        console.print(f"  [{STEEL_BLUE}]cluster show network[/{STEEL_BLUE}]\n")
        return

    if target in ("machines", "nodes"):
        status_data = client.get_status()
        flake_specs = status_data.get("flake_specs", {})
        wipe_data = status_data.get("wipe_data", {})
        discovered_nodes = status_data.get("discovered_nodes", [])
        machines_data = get_machines_data()

        merged = merge_cluster_nodes(machines_data or flake_specs, wipe_data, discovered_nodes)
        print_header("Cluster Machine Specifications", f"(http://{coordinator_host}:8080)")
        console.print(render_machines_table(merged))
        console.print()

    elif target in ("config", "configs"):
        if not name:
            print_error("Please specify node name or config file (e.g. cluster show config control)")
            raise typer.Exit(code=1)

        conf_file = name if name.endswith(".yaml") or name == "talosconfig" else f"{name}.yaml"
        code, body = client.get_config(conf_file)
        if code == 200:
            print_header(f"Rendered Talos Config for {name} ({conf_file}):")
            console.print(body)
        elif code == 404:
            print_error(f"Config '{conf_file}' not found on Coordinator.")
            raise typer.Exit(code=1)
        elif code == 403:
            print_warning(f"Access to config '{conf_file}' is forbidden.")
            raise typer.Exit(code=1)
        else:
            print_error(f"Failed to fetch config '{conf_file}': {body or f'HTTP {code}'}")
            raise typer.Exit(code=1)

    elif target in ("report", "reports"):
        if not name:
            code, body = client.get_reports()
            if code == 200:
                try:
                    data = json.loads(body)
                    reports = data.get("reports", [])
                    print_header(f"Hardware Inspector Reports on Coordinator ({coordinator_host}):")
                    if not reports:
                        print_dim("  (No reports found on coordinator)\n")
                        return
                    for r in reports:
                        fn = r.get("filename")
                        sz = r.get("size_bytes", 0)
                        console.print(f"  - [{STEEL_BLUE}]{fn}[/{STEEL_BLUE}] ({sz} bytes)")
                    print_dim("\nRun `cluster show report <node>` to view a specific report.\n")
                except Exception as e:
                    print_error(f"Failed to parse report list: {e}")
                    raise typer.Exit(code=1)
            else:
                print_error(f"Failed to fetch report list: {body or f'HTTP {code}'}")
                raise typer.Exit(code=1)
        else:
            code, body = client.get_reports(name)
            if code == 200:
                print_header(f"Hardware Inspector Report for {name}:")
                console.print(body)
            elif code == 404:
                print_warning(f"No hardware report found for node '{name}' on Coordinator.")
                raise typer.Exit(code=1)
            else:
                print_error(f"Failed to fetch hardware report: {body or f'HTTP {code}'}")
                raise typer.Exit(code=1)

    elif target in ("network", "net"):
        status_data = client.get_status()
        vip_ip = get_control_vip()
        endpoint = get_endpoint() or (f"https://{vip_ip}:6443" if vip_ip else "-")

        print_header("AI Village Cluster Network Architecture")
        console.print(f"  Coordinator Host : [{STEEL_BLUE}]{status_data.get('coordinator_host', coordinator_host)}[/{STEEL_BLUE}]")
        console.print(f"  Coordinator IP   : [{STEEL_BLUE}]{status_data.get('coordinator_ip') or status_data.get('dns_ip') or coordinator_host}[/{STEEL_BLUE}]")
        console.print(f"  Gateway Router   : [{STEEL_BLUE}]{status_data.get('gateway_ip', '-')}[/{STEEL_BLUE}]")
        console.print(f"  Private Subnet   : [{STEEL_BLUE}]{status_data.get('private_subnet', '-')}[/{STEEL_BLUE}] (VLAN 10)")
        console.print(f"  Public Subnet    : [{STEEL_BLUE}]{status_data.get('public_subnet', '-')}[/{STEEL_BLUE}] (VLAN 20)")
        console.print(f"  Control VIP      : [{STEEL_BLUE}]{vip_ip or '-'}[/{STEEL_BLUE}]")
        console.print(f"  K8s API Endpoint : [{STEEL_BLUE}]{endpoint}[/{STEEL_BLUE}]\n")

    else:
        print_error(f"Unknown show target '{target}'. Use `cluster show help` for options.")
        raise typer.Exit(code=1)

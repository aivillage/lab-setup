import typer
from typing import Optional

from cluster_cli.config import get_coordinator_host, get_machines_data
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
    print_success,
    print_error,
    print_warning,
    print_dim,
)
from cluster_cli.views.tables import merge_cluster_nodes, render_wipe_status_table

wipe_app = typer.Typer(
    name="wipe",
    help="Inspect, request, or cancel bare-metal node disk wipes",
    no_args_is_help=False,
)


@wipe_app.callback(invoke_without_command=True)
def wipe_default(ctx: typer.Context) -> None:
    """Default handler for 'cluster wipe' without subcommand (shows wipe status)."""
    if ctx.invoked_subcommand is None:
        wipe_status()


@wipe_app.command("status")
def wipe_status() -> None:
    """Display bare-metal node registration and wipe states."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)
    status_data = client.get_status()
    wipe_data = status_data.get("wipe_data", {})
    discovered_nodes = status_data.get("discovered_nodes", [])
    machines = get_machines_data()

    print_header(
        "Bare-Metal Node Registration & Wipe State", f"(http://{coordinator_host}:8080)"
    )
    merged = merge_cluster_nodes(machines, wipe_data, discovered_nodes)
    if not merged:
        print_dim("  (No registered nodes or wipe records found)\n")
        return

    console.print(render_wipe_status_table(merged))
    console.print()


@wipe_app.command("request")
def wipe_request(
    target: str = typer.Argument(
        default="all", help="Target node name, MAC address, or 'all'"
    ),
    yes: bool = typer.Option(
        False, "-y", "--yes", help="Skip destructive wipe confirmation prompt"
    ),
) -> None:
    """Request disk wipe for target node(s) on next netboot."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if not yes:
        console.print(f"\n[bold {CRIMSON}]WARNING: Destructive Storage Wipe Request[/bold {CRIMSON}]")
        console.print(f"  Target : [bold]{target}[/bold]")
        console.print("  Action : All physical NVMe/SATA storage will be permanently wiped on next netboot.\n")
        confirm = typer.confirm(f"Are you sure you want to request a disk wipe for '{target}'?")
        if not confirm:
            print_warning("Wipe request canceled. Disks untouched.\n")
            return

    console.print(
        f"Requesting wipe for '{target}' via Coordinator ({coordinator_host})..."
    )
    ok, msg = client.send_wipe_request(target, requested=True)
    if ok:
        print_success(
            f"Wipe marked as REQUESTED for '{target}'. Node will be wiped by Inspector on next netboot."
        )
    else:
        print_error(f"Failed to update wipe state: {msg}")


@wipe_app.command("cancel")
def wipe_cancel(
    target: str = typer.Argument(
        default="all", help="Target node name, MAC address, or 'all'"
    ),
) -> None:
    """Cancel pending disk wipe for target node(s)."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    console.print(
        f"Canceling wipe request for '{target}' via Coordinator ({coordinator_host})..."
    )
    ok, msg = client.send_wipe_request(target, requested=False)
    if ok:
        print_success(
            f"Wipe request CANCELED for '{target}'. Node will boot normally into Talos OS."
        )
    else:
        print_error(f"Failed to update wipe state: {msg}")


@wipe_app.command("logs")
def wipe_logs(
    target: str = typer.Argument(..., help="Target node name or MAC address"),
) -> None:
    """Fetch last wipe log from Coordinator for a node."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)
    code, body = client.get_wipelog(target)
    if code == 200:
        print_header(f"Last Wipe Log for {target}:")
        console.print(body)
    elif code == 404:
        print_warning(f"No wipe logs found on Coordinator for node '{target}'.")
    else:
        print_error(f"Failed to fetch wipe log: {body or f'HTTP {code}'}")

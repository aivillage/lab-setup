import json
from pathlib import Path
import shutil
import typer

from cluster_cli.config import get_coordinator_host
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
    print_info,
)


def purge_command(
    local: bool = typer.Option(
        True,
        "--local/--remote-only",
        help="Purge local machines.nix and .cluster/ state as well as coordinator state",
    ),
    yes: bool = typer.Option(
        False, "-y", "--yes", help="Skip destructive operation confirmation prompt"
    ),
) -> None:
    """Purge coordinator state, discovery reports, wipe logs, and local state."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if not yes:
        console.print(f"\n[bold {AMBER}][WARNING] This is a destructive operation![/bold {AMBER}]")
        console.print(
            f"  • Will purge all discovery reports, wipe logs, and state files on Coordinator ({coordinator_host})"
        )
        if local:
            console.print("  • Will delete local machines.nix and .cluster/ state directories")
        console.print()
        confirm = typer.confirm("Are you sure you want to proceed with cluster purge?")
        if not confirm:
            print_warning("Operation cancelled.")
            return

    print_info(f"Purging coordinator reports, wipe logs, and state ({coordinator_host})...")
    code, body = client.purge()
    if code == 200:
        try:
            data = json.loads(body)
            print_success(
                f"{data.get('message', 'Coordinator state cleared.')} (Items purged: {data.get('purged_items', 0)})"
            )
        except Exception:
            print_success("Coordinator state purged successfully.")
    else:
        print_error(f"Failed to purge coordinator state: {body or f'HTTP {code}'}")
        raise typer.Exit(code=1)

    if local:
        if Path("machines.nix").exists():
            Path("machines.nix").unlink(missing_ok=True)
            print_success("Removed local machines.nix")
        if Path(".cluster").exists():
            shutil.rmtree(".cluster", ignore_errors=True)
            print_success("Removed local .cluster state directory")

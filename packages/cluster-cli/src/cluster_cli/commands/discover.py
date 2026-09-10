from pathlib import Path
import typer

from cluster_cli.config import get_coordinator_host
from cluster_cli.clients.coordinator import CoordinatorClient
from cluster_cli.views.console import (
    console,
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    print_header,
    print_success,
    print_error,
    print_dim,
)


def discover_command(
    write: bool = typer.Option(
        False, "-w", "--write", help="Write discovered hardware specification directly to ./machines.nix"
    ),
) -> None:
    """Fetch auto-generated hardware specification from Coordinator."""
    coordinator_host = get_coordinator_host()
    client = CoordinatorClient(coordinator_host)

    if write:
        out_file = Path("machines.nix")
        console.print(
            f"Generating [bold]{out_file}[/bold] from Coordinator ({coordinator_host})..."
        )
        code, content = client.get_discovered_nix()
        if code != 200 or not content:
            print_error(f"Failed to fetch discovered hardware: {content or f'HTTP {code}'}")
            raise typer.Exit(code=1)
        out_file.write_text(content, encoding="utf-8")
        print_success(f"Generated {out_file} from Coordinator\n")
    else:
        print_header(f"Discovered Machine Definitions from Coordinator ({coordinator_host}):")
        code, content = client.get_discovered_nix()
        if code == 200 and content:
            console.print(content)
            print_dim("\nRun `cluster discover -w` or `cluster gen machines` to save this to ./machines.nix\n")
        else:
            print_error(f"Failed to fetch discovered machines: {content or f'HTTP {code}'}")
            raise typer.Exit(code=1)

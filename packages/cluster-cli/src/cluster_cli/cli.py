import typer

from cluster_cli.commands.status import status_command
from cluster_cli.commands.power import wakeup_command, shutdown_command
from cluster_cli.commands.wipe import wipe_app
from cluster_cli.commands.discover import discover_command
from cluster_cli.commands.talos import (
    gen_command,
    apply_command,
    bootstrap_command,
    pull_secrets_command,
    cache_app,
)
from cluster_cli.commands.show import show_command
from cluster_cli.commands.purge import purge_command

app = typer.Typer(
    name="cluster",
    help="AI Village Cluster CLI - Unified Operational Tooling",
    no_args_is_help=True,
    rich_markup_mode="rich",
)

# Register top-level subcommands
app.command(name="status", help="Inspect live registered nodes, K8s health & GPU status")(status_command)
app.command(name="wakeup", help="Wake up node(s) or entire cluster via Wake-on-LAN")(wakeup_command)
app.command(name="shutdown", help="Gracefully shut down node(s) or entire cluster")(shutdown_command)
app.add_typer(wipe_app, name="wipe")
app.command(name="discover", help="Fetch auto-generated hardware specification from Coordinator")(discover_command)
app.command(name="pull-secrets", help="Fetch canonical secrets & talosconfig from Coordinator")(pull_secrets_command)
app.command(name="gen", help="Render Talos OS node configs, K8s manifests, or PKI secrets")(gen_command)
app.command(name="apply", help="Apply Talos node configuration or Kubernetes manifests")(apply_command)
app.command(name="bootstrap", help="Bootstrap ETCD cluster on control plane and sync credentials")(bootstrap_command)
app.command(name="show", help="Inspect machines, rendered configs, reports, or network architecture")(show_command)
app.command(name="purge", help="Purge all discovered hardware reports, wipe states, and local artifacts")(purge_command)
app.add_typer(cache_app, name="cache")


def main() -> None:
    app()


if __name__ == "__main__":
    main()

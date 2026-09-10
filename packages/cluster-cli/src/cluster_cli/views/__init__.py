"""Views and Rich formatting helpers for Cluster CLI."""

from cluster_cli.views.console import (
    console,
    GOLD,
    STEEL_BLUE,
    SAGE_GREEN,
    MUTED_GREY,
    print_header,
    print_success,
    print_error,
    print_warning,
    print_info,
    print_dim,
)
from cluster_cli.views.tables import (
    merge_cluster_nodes,
    render_cluster_status_table,
    render_wipe_status_table,
    render_k8s_nodes_table,
    render_gpu_nodes_table,
    render_machines_table,
)

__all__ = [
    "console",
    "GOLD",
    "STEEL_BLUE",
    "SAGE_GREEN",
    "MUTED_GREY",
    "print_header",
    "print_success",
    "print_error",
    "print_warning",
    "print_info",
    "print_dim",
    "merge_cluster_nodes",
    "render_cluster_status_table",
    "render_wipe_status_table",
    "render_k8s_nodes_table",
    "render_gpu_nodes_table",
    "render_machines_table",
]

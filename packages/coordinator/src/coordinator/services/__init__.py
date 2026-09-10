"""Services for Coordinator backend state, hardware discovery, and template rendering."""

from coordinator.services.state_store import (
    normalize_mac,
    format_mac,
    atomic_save_text,
    atomic_save_json,
    get_flake_machines,
    get_wipe_data,
    save_wipe_data,
    get_discovered_nodes,
    resolve_target_macs,
    prune_secondary_mac_keys,
    save_wipe_log,
    save_inspector_report,
    purge_all_state,
)
from coordinator.services.hardware import (
    compile_hardware_reports,
    generate_machines_nix,
    get_discovered_nodes_data,
)
from coordinator.services.ipxe_render import (
    render_wipe_script,
    render_discover_script,
    render_talos_script,
)

__all__ = [
    "normalize_mac",
    "format_mac",
    "atomic_save_text",
    "atomic_save_json",
    "get_flake_machines",
    "get_wipe_data",
    "save_wipe_data",
    "get_discovered_nodes",
    "resolve_target_macs",
    "prune_secondary_mac_keys",
    "save_wipe_log",
    "save_inspector_report",
    "purge_all_state",
    "compile_hardware_reports",
    "generate_machines_nix",
    "get_discovered_nodes_data",
    "render_wipe_script",
    "render_discover_script",
    "render_talos_script",
]

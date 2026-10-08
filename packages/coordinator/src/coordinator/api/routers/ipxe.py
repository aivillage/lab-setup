from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Query, Request, Response

from coordinator.config import settings
from coordinator.services.state_store import (
    normalize_mac,
    format_mac,
    get_wipe_data,
    save_wipe_data,
    get_flake_machines,
    get_discovered_nodes,
    resolve_target_macs,
    prune_secondary_mac_keys,
)
from coordinator.services.ipxe_render import (
    render_wipe_script,
    render_discover_script,
    render_talos_script,
)

router = APIRouter(tags=["ipxe"])


@router.get("/boot.ipxe", response_class=Response)
@router.get("/ipxe/boot.ipxe", response_class=Response)
def get_boot_ipxe(
    request: Request,
    mac: Optional[str] = Query(default="", description="Client network interface MAC address"),
) -> Response:
    """Renders dynamic iPXE boot configuration tailored to the requesting node's MAC address."""
    clean_req_mac = normalize_mac(mac)
    formatted_req_mac = format_mac(clean_req_mac)

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    iso_now = datetime.now(timezone.utc).isoformat()

    # Check if MAC is declared in cluster flake machines
    declared_name = None
    is_control_plane = False
    is_nvidia = False

    if flake_machines:
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict):
                fmacs = [normalize_mac(m) for m in fspec.get("macs", [])]
                if clean_req_mac in fmacs:
                    declared_name = fname
                    is_control_plane = bool(fspec.get("controlPlane"))
                    is_nvidia = bool(fspec.get("nvidia"))
                    break

    is_declared = declared_name is not None
    name = declared_name or f"node-{clean_req_mac[-6:] if clean_req_mac else 'unknown'}"
    vmlinuz_path = Path("/var/lib/tftpboot") / name / "vmlinuz"

    discovered_nodes = get_discovered_nodes()
    target_macs = resolve_target_macs(clean_req_mac, flake_machines, discovered_nodes)
    canonical_mac = target_macs[0] if target_macs else formatted_req_mac

    prune_secondary_mac_keys(wipe_data, canonical_mac, flake_machines, discovered_nodes)

    # Check wipe request for this MAC
    wentry = wipe_data.get(canonical_mac, {})
    should_wipe = wentry.get("requested", False) or wentry.get("status") == "IN_PROGRESS"

    if should_wipe:
        boot_target = "Inspector (Wipe)"
    elif not is_declared or not vmlinuz_path.exists():
        boot_target = "Inspector (Discover)"
    else:
        boot_target = "Talos"

    # Determine coordinator server IP to pass in boot arguments
    host_header = request.headers.get("host", settings.DNS_IP)
    server_ip = host_header.split(":")[0] if host_header else settings.DNS_IP
    if server_ip in ("127.0.0.1", "localhost") and settings.DNS_IP not in ("127.0.0.1", "localhost"):
        server_ip = settings.DNS_IP

    client_ip = request.client.host if request.client else None

    if canonical_mac not in wipe_data:
        wipe_data[canonical_mac] = {
            "requested": should_wipe,
            "status": "IN_PROGRESS" if should_wipe else "NONE",
            "timestamp": iso_now,
            "log": None,
            "pxe_ip": client_ip,
            "installed": False,
            "installed_at": None,
        }
    else:
        if client_ip:
            wipe_data[canonical_mac]["pxe_ip"] = client_ip
        if should_wipe:
            wipe_data[canonical_mac]["status"] = "IN_PROGRESS"
            wipe_data[canonical_mac]["timestamp"] = iso_now
            wipe_data[canonical_mac]["installed"] = False

    save_wipe_data(wipe_data)

    if boot_target == "Inspector (Wipe)":
        script_content = render_wipe_script(
            name=name, mac=formatted_req_mac, server_ip=server_ip, port=settings.PORT
        )
    elif boot_target == "Inspector (Discover)":
        script_content = render_discover_script(
            name=name, mac=formatted_req_mac, server_ip=server_ip, port=settings.PORT
        )
    else:
        config_url = f"http://{server_ip}:{settings.PORT}/configs/{name}.yaml"
        script_content = render_talos_script(
            name=name,
            mac=formatted_req_mac,
            server_ip=server_ip,
            port=settings.PORT,
            is_control_plane=is_control_plane,
            is_nvidia=is_nvidia,
            config_url=config_url,
        )

    return Response(content=script_content, media_type="text/plain")

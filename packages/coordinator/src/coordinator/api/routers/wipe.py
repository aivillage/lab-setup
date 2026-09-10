import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status

from coordinator.config import settings
from coordinator.api.deps import require_local_auth
from coordinator.schemas.wipe import (
    WipeRequest,
    WipeResponse,
    InstalledRequest,
    InstalledResponse,
    WipeLogResponse,
)
from coordinator.schemas.status import CoordinatorStatusResponse
from coordinator.services.state_store import (
    normalize_mac,
    format_mac,
    get_flake_machines,
    get_discovered_nodes,
    get_wipe_data,
    save_wipe_data,
    resolve_target_macs,
    prune_secondary_mac_keys,
    save_wipe_log,
)

router = APIRouter(tags=["wipe"])


@router.get(
    "/api/wipe",
    dependencies=[Depends(require_local_auth)],
    response_model=CoordinatorStatusResponse,
    summary="Get wipe status for cluster nodes",
)
def get_wipe_status() -> CoordinatorStatusResponse:
    """Returns cluster nodes status and wipe tracking records (Localhost / SSH only)."""
    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()

    return CoordinatorStatusResponse(
        coordinator_host=settings.HOSTNAME,
        dns_ip=settings.DNS_IP,
        gateway_ip=settings.GATEWAY_IP,
        private_subnet=settings.PRIVATE_SUBNET,
        public_subnet=settings.PUBLIC_SUBNET,
        flake_machines=list(flake_machines.keys()),
        flake_specs=flake_machines,
        discovered_nodes=get_discovered_nodes(),
        wipe_data=wipe_data,
    )


@router.post(
    "/api/wipe",
    dependencies=[Depends(require_local_auth)],
    response_model=WipeResponse,
    summary="Request or cancel disk wipe for node(s)",
)
def post_wipe(req: WipeRequest) -> WipeResponse:
    """Allows requesting or canceling disk wipe for target nodes (Localhost / SSH only)."""
    target = req.target or "all"
    requested = req.requested
    explicit_status = req.status

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    discovered_nodes = get_discovered_nodes()
    iso_now = datetime.now(timezone.utc).isoformat()

    target_macs = resolve_target_macs(target, flake_machines, discovered_nodes)
    if not target_macs:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Target '{target}' is not a declared node in machines.nix or a discovered bare-metal node.",
        )

    for mac in target_macs:
        if mac not in wipe_data:
            wipe_data[mac] = {
                "requested": False,
                "status": "NONE",
                "timestamp": None,
                "log": None,
                "installed": False,
                "installed_at": None,
            }
        if requested is not None:
            wipe_data[mac]["requested"] = requested
            if requested:
                wipe_data[mac]["installed"] = False
        if explicit_status:
            wipe_data[mac]["status"] = explicit_status
        else:
            wipe_data[mac]["status"] = (
                "PENDING" if (requested if requested is not None else False) else "NONE"
            )
        wipe_data[mac]["timestamp"] = iso_now

    save_wipe_data(wipe_data)

    return WipeResponse(
        status="success",
        target=target,
        resolved_macs=target_macs,
        wipe_requested=requested,
        node_status=explicit_status,
    )


@router.get("/api/wipelog", summary="Fetch latest storage wipe log for a node")
def get_wipelog(
    node: Optional[str] = Query(default=None, description="Target node name or MAC address"),
    hostname: Optional[str] = Query(default=None, description="Alternative target node name"),
) -> Response:
    """Returns the latest storage wipe log text for a given node."""
    target = node or hostname
    if not target:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Node or hostname query parameter is required.",
        )

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    discovered = get_discovered_nodes()

    target_macs = resolve_target_macs(target, flake_machines, discovered) if target else []
    target_mac = (
        target_macs[0]
        if target_macs
        else (format_mac(target) if len(normalize_mac(target)) == 12 else target)
    )

    log_path: Optional[str] = None
    if target_mac in wipe_data and wipe_data[target_mac].get("log"):
        log_path = wipe_data[target_mac]["log"]
    elif target_mac:
        clean_mac = target_mac.replace(":", "-")
        for p in sorted(settings.wipe_logs_dir.glob(f"*{clean_mac}*.log"), reverse=True):
            log_path = str(p)
            break

    if log_path and Path(log_path).exists():
        return Response(
            content=Path(log_path).read_text(encoding="utf-8", errors="replace"),
            media_type="text/plain",
        )

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail=f"Wipe log not found for target '{target}'.",
    )


@router.post("/api/wipelog", response_model=WipeLogResponse, summary="Receive storage wipe log")
async def post_wipelog(
    request: Request,
    hostname: Optional[str] = Query(default=None),
) -> WipeLogResponse:
    """Receives and stores disk sanitization logs posted from Inspector wipe RAMdisk."""
    body_bytes = await request.body()
    payload = body_bytes.decode("utf-8", errors="replace")

    req_hostname = hostname or request.headers.get("x-hostname") or "unknown"
    macs = re.findall(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", payload)
    clean_macs = [normalize_mac(m) for m in macs]
    norm_req = normalize_mac(req_hostname)
    if norm_req and norm_req not in clean_macs:
        clean_macs.append(norm_req)

    flake_machines = get_flake_machines()
    discovered_nodes = get_discovered_nodes()

    target_macs: list[str] = []
    for m in clean_macs:
        resolved = resolve_target_macs(m, flake_machines, discovered_nodes)
        if resolved:
            target_macs = resolved
            break

    if not target_macs and req_hostname:
        target_macs = resolve_target_macs(req_hostname, flake_machines, discovered_nodes)

    target_mac = (
        target_macs[0]
        if target_macs
        else (format_mac(clean_macs[0]) if clean_macs else req_hostname)
    )

    log_path = save_wipe_log(target_mac, payload, req_hostname)
    return WipeLogResponse(status="SUCCESS", log_file=str(log_path))


@router.post(
    "/api/installed",
    dependencies=[Depends(require_local_auth)],
    response_model=InstalledResponse,
    summary="Toggle node installed state",
)
@router.post(
    "/api/mark-installed",
    dependencies=[Depends(require_local_auth)],
    response_model=InstalledResponse,
    summary="Toggle node installed state (alias)",
)
def post_installed(req: InstalledRequest) -> InstalledResponse:
    """Sets or toggles node installed state in wipe_data (Localhost / SSH only)."""
    target = req.target or "all"
    installed = req.installed

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    discovered_nodes = get_discovered_nodes()
    iso_now = datetime.now(timezone.utc).isoformat()

    target_macs = resolve_target_macs(target, flake_machines, discovered_nodes)
    if not target_macs:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Target '{target}' is not a declared node in machines.nix or a discovered bare-metal node.",
        )

    for mac in target_macs:
        if mac not in wipe_data:
            wipe_data[mac] = {
                "requested": False,
                "status": "NONE",
                "timestamp": None,
                "log": None,
                "installed": False,
                "installed_at": None,
            }
        wipe_data[mac]["installed"] = installed
        wipe_data[mac]["installed_at"] = iso_now if installed else None
        if installed:
            wipe_data[mac]["requested"] = False

    save_wipe_data(wipe_data)
    return InstalledResponse(
        status="success",
        target=target,
        resolved_macs=target_macs,
        installed=installed,
    )

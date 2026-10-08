from fastapi import APIRouter, Depends, Response
from fastapi.responses import PlainTextResponse

from coordinator.config import settings
from coordinator.api.deps import require_local_auth
from coordinator.schemas.status import (
    HealthResponse,
    CoordinatorStatusResponse,
    DiscoveredNodesResponse,
    PurgeResponse,
)
from coordinator.services.state_store import (
    get_flake_machines,
    get_discovered_nodes,
    get_wipe_data,
    purge_all_state,
)
from coordinator.services.hardware import (
    compile_hardware_reports,
    get_discovered_nodes_data,
)

router = APIRouter(tags=["status"])


@router.get("/health", response_model=HealthResponse, summary="Coordinator health check")
def get_health() -> HealthResponse:
    """Returns basic service health status."""
    return HealthResponse(status="healthy", service="coordinator")


@router.get(
    "/api/status",
    dependencies=[Depends(require_local_auth)],
    response_model=CoordinatorStatusResponse,
    summary="Coordinator live discovery and cluster status",
)
def get_status() -> CoordinatorStatusResponse:
    """Returns coordinator cluster status, declared machines, discovered nodes, and wipe states."""
    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()

    return CoordinatorStatusResponse(
        coordinator_host=settings.HOSTNAME,
        coordinator_ip=settings.COORDINATOR_IP,
        dns_ip=settings.COORDINATOR_IP,
        gateway_ip=settings.GATEWAY_IP,
        private_subnet=settings.PRIVATE_SUBNET,
        public_subnet=settings.PUBLIC_SUBNET,
        flake_machines=list(flake_machines.keys()),
        flake_specs=flake_machines,
        discovered_nodes=get_discovered_nodes(),
        wipe_data=wipe_data,
    )


@router.get(
    "/api/discovered",
    dependencies=[Depends(require_local_auth)],
    response_model=DiscoveredNodesResponse,
    summary="Get discovered bare-metal nodes JSON",
)
@router.get(
    "/api/discovered/machines.json",
    dependencies=[Depends(require_local_auth)],
    response_model=DiscoveredNodesResponse,
    summary="Get discovered bare-metal nodes JSON (alias)",
)
def get_discovered() -> DiscoveredNodesResponse:
    """Returns JSON representation of all hardware-inspected bare-metal nodes (Localhost / SSH only)."""
    nodes = get_discovered_nodes_data()
    return DiscoveredNodesResponse(nodes=nodes)


@router.get(
    "/api/discovered/machines.nix",
    dependencies=[Depends(require_local_auth)],
    response_class=PlainTextResponse,
    summary="Generate machines.nix from discovered hardware reports",
)
@router.get(
    "/api/discovered/nix",
    dependencies=[Depends(require_local_auth)],
    response_class=PlainTextResponse,
    summary="Generate machines.nix from discovered hardware reports (alias)",
)
def get_discovered_nix() -> PlainTextResponse:
    """Dynamically compiles all hardware reports into Nix attribute set syntax."""
    nix_body, _ = compile_hardware_reports()
    return PlainTextResponse(content=nix_body, media_type="text/plain")


@router.get(
    "/api/purge",
    dependencies=[Depends(require_local_auth)],
    response_model=PurgeResponse,
    summary="Purge coordinator state and reports",
)
@router.post(
    "/api/purge",
    dependencies=[Depends(require_local_auth)],
    response_model=PurgeResponse,
    summary="Purge coordinator state and reports (POST)",
)
def handle_purge() -> PurgeResponse:
    """Purges all inspector reports, wipe states, logs, and generated Talos state files (Localhost / SSH only)."""
    purged_count = purge_all_state()
    return PurgeResponse(
        status="PURGED",
        purged_items=purged_count,
        message="All coordinator reports, wipe logs, and state files cleared.",
    )

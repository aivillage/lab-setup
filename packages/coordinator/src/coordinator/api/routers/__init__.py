"""Coordinator API Routers."""

from coordinator.api.routers.ipxe import router as ipxe_router
from coordinator.api.routers.reports import router as reports_router
from coordinator.api.routers.wipe import router as wipe_router
from coordinator.api.routers.status import router as status_router
from coordinator.api.routers.configs import router as configs_router

__all__ = [
    "ipxe_router",
    "reports_router",
    "wipe_router",
    "status_router",
    "configs_router",
]

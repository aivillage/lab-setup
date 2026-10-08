"""Pydantic v2 schemas for Coordinator data models."""

from coordinator.schemas.hardware import (
    NetworkDevice,
    NetworkInterface,
    NetworkInfo,
    BlockDevice,
    TPMInfo,
    InspectorReport,
)
from coordinator.schemas.wipe import (
    WipeEntry,
    WipeRequest,
    WipeResponse,
    InstalledRequest,
    InstalledResponse,
    WipeLogResponse,
)
from coordinator.schemas.status import (
    HealthResponse,
    DiscoveredNode,
    DiscoveredNodesResponse,
    CoordinatorStatusResponse,
    PurgeResponse,
    ReportSummary,
    ReportsListResponse,
)

__all__ = [
    "NetworkDevice",
    "NetworkInterface",
    "NetworkInfo",
    "BlockDevice",
    "TPMInfo",
    "InspectorReport",
    "WipeEntry",
    "WipeRequest",
    "WipeResponse",
    "InstalledRequest",
    "InstalledResponse",
    "WipeLogResponse",
    "HealthResponse",
    "DiscoveredNode",
    "DiscoveredNodesResponse",
    "CoordinatorStatusResponse",
    "PurgeResponse",
    "ReportSummary",
    "ReportsListResponse",
]

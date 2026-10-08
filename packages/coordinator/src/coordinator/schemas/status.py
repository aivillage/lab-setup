from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: str = "healthy"
    service: str = "coordinator"


class DiscoveredNode(BaseModel):
    name: str
    controlPlane: bool = False
    nvidia: bool = False
    tpm: Dict[str, Any] = Field(default_factory=lambda: {"present": False})
    macs: List[str] = Field(default_factory=list)
    primary_mac: Optional[str] = None
    pxe_ip: Optional[str] = None
    iface: Optional[str] = None


class DiscoveredNodesResponse(BaseModel):
    nodes: List[DiscoveredNode] = Field(default_factory=list)


class CoordinatorStatusResponse(BaseModel):
    coordinator_host: str
    coordinator_ip: Optional[str] = None
    dns_ip: Optional[str] = None
    gateway_ip: str
    private_subnet: str
    public_subnet: str
    flake_machines: List[str] = Field(default_factory=list)
    flake_specs: Dict[str, Any] = Field(default_factory=dict)
    discovered_nodes: List[Dict[str, Any]] = Field(default_factory=list)
    wipe_data: Dict[str, Dict[str, Any]] = Field(default_factory=dict)


class PurgeResponse(BaseModel):
    status: str
    purged_items: int
    message: str


class ReportSummary(BaseModel):
    filename: str
    size_bytes: int
    modified_at: float


class ReportsListResponse(BaseModel):
    count: int
    reports: List[ReportSummary] = Field(default_factory=list)

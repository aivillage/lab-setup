from typing import Optional, List
from pydantic import BaseModel, Field


class NetworkDevice(BaseModel):
    name: str
    mac_address: str


class NetworkInterface(BaseModel):
    iface: str
    mac: Optional[str] = None
    ips: List[str] = Field(default_factory=list)


class NetworkInfo(BaseModel):
    primary_iface: Optional[str] = None
    primary_mac: Optional[str] = None
    primary_ip: Optional[str] = None
    interfaces: List[NetworkInterface] = Field(default_factory=list)


class BlockDevice(BaseModel):
    name: str
    size_bytes: int
    by_id: Optional[str] = None
    model: Optional[str] = None
    transport: Optional[str] = None


class TPMInfo(BaseModel):
    present: bool = False
    version: Optional[str] = None
    device: Optional[str] = None


class InspectorReport(BaseModel):
    hostname: Optional[str] = None
    primary_mac: Optional[str] = None
    primary_ip: Optional[str] = None
    primary_iface: Optional[str] = None
    network_devices: List[NetworkDevice] = Field(default_factory=list)
    network: Optional[NetworkInfo] = None
    block_devices: List[BlockDevice] = Field(default_factory=list)
    tpm: Optional[TPMInfo] = None
    raw_yaml: Optional[str] = None

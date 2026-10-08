from enum import Enum
from typing import Optional, List
from pydantic import BaseModel, Field


class WipeStatus(str, Enum):
    NONE = "NONE"
    PENDING = "PENDING"
    IN_PROGRESS = "IN_PROGRESS"
    SUCCESS = "SUCCESS"
    FAILED = "FAILED"


class WipeEntry(BaseModel):
    requested: bool = False
    status: str = "NONE"
    timestamp: Optional[str] = None
    log: Optional[str] = None
    pxe_ip: Optional[str] = None
    installed: bool = False
    installed_at: Optional[str] = None


class WipeRequest(BaseModel):
    target: str = "all"
    requested: Optional[bool] = None
    status: Optional[str] = None


class WipeResponse(BaseModel):
    status: str
    target: str
    resolved_macs: List[str] = Field(default_factory=list)
    wipe_requested: Optional[bool] = None
    node_status: Optional[str] = None


class InstalledRequest(BaseModel):
    target: str = "all"
    installed: bool = True


class InstalledResponse(BaseModel):
    status: str
    target: str
    resolved_macs: List[str] = Field(default_factory=list)
    installed: bool


class WipeLogResponse(BaseModel):
    status: str
    log_file: str

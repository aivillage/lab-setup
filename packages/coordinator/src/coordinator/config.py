from pathlib import Path
from typing import Optional
from pydantic_settings import BaseSettings
from pydantic import Field


class Settings(BaseSettings):
    """Runtime configuration settings for AI Village Coordinator service."""

    PORT: int = Field(default=8080, validation_alias="PORT")
    COORDINATOR_ROOT: Path = Field(default=Path("/var/lib/coordinator"), validation_alias="COORDINATOR_ROOT")
    CONFIGS_DIR: Path = Field(default=Path("/var/lib/tftpboot/configs"), validation_alias="CONFIGS_DIR")
    COORDINATOR_IP: str = Field(default="127.0.0.1", validation_alias="COORDINATOR_IP")
    DNS_IP: str = Field(default="127.0.0.1", validation_alias="DNS_IP")
    GATEWAY_IP: str = Field(default="127.0.0.1", validation_alias="GATEWAY_IP")
    PRIVATE_SUBNET: str = Field(default="", validation_alias="PRIVATE_SUBNET")
    PUBLIC_SUBNET: str = Field(default="", validation_alias="PUBLIC_SUBNET")
    FLAKE_MACHINES_FILE: Optional[str] = Field(default=None, validation_alias="FLAKE_MACHINES_FILE")
    FLAKE_MACHINES_JSON: Optional[str] = Field(default=None, validation_alias="FLAKE_MACHINES_JSON")
    SECRETS_FILE: Optional[str] = Field(default=None, validation_alias="SECRETS_FILE")
    HOSTNAME: str = Field(default="coordinator", validation_alias="HOSTNAME")

    @property
    def inspector_dir(self) -> Path:
        return self.COORDINATOR_ROOT / "inspector"

    @property
    def talos_dir(self) -> Path:
        return self.COORDINATOR_ROOT / "talos"

    @property
    def wipe_dir(self) -> Path:
        return self.COORDINATOR_ROOT / "wipe"

    @property
    def wipe_logs_dir(self) -> Path:
        return self.wipe_dir / "logs"

    @property
    def wipe_file(self) -> Path:
        return self.wipe_dir / "wipe.json"

    def ensure_directories(self) -> None:
        """Ensures all required runtime directories exist on the filesystem."""
        for d in [self.inspector_dir, self.talos_dir, self.wipe_dir, self.wipe_logs_dir]:
            d.mkdir(parents=True, exist_ok=True)

    model_config = {
        "env_file": ".env",
        "extra": "ignore",
    }


settings = Settings()

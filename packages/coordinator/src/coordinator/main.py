from contextlib import asynccontextmanager
from fastapi import FastAPI
import uvicorn

from coordinator.config import settings
from coordinator.api.routers import (
    ipxe_router,
    reports_router,
    wipe_router,
    status_router,
    configs_router,
)
from coordinator.services.state_store import get_wipe_data


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initializes runtime storage directories and state on application startup."""
    settings.ensure_directories()
    try:
        get_wipe_data()
    except Exception as e:
        print(f"[WARN] Failed to initialize wipe state on startup: {e}", flush=True)

    print(f"AI Village Cluster Coordinator started on port {settings.PORT}", flush=True)
    print(
        f"Configs: {settings.CONFIGS_DIR.resolve()} | State: {settings.COORDINATOR_ROOT.resolve()}",
        flush=True,
    )
    yield
    print("Coordinator service shutting down.", flush=True)


def create_app() -> FastAPI:
    """FastAPI Application factory for Coordinator."""
    app = FastAPI(
        title="AI Village Cluster Coordinator",
        description="Bare-metal node discovery, iPXE netboot routing, disk wipe lifecycle, and Talos configuration daemon.",
        version="1.0.0",
        lifespan=lifespan,
    )

    # Register Routers
    app.include_router(ipxe_router)
    app.include_router(reports_router)
    app.include_router(wipe_router)
    app.include_router(status_router)
    app.include_router(configs_router)

    return app


app = create_app()


def run() -> None:
    """Runs the Coordinator service using Uvicorn."""
    uvicorn.run(
        "coordinator.main:app",
        host="0.0.0.0",
        port=settings.PORT,
        log_level="info",
    )


if __name__ == "__main__":
    run()

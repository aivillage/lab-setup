import logging
import os
import subprocess
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, Response, status

from coordinator.config import settings
from coordinator.services.state_store import get_flake_machines

logger = logging.getLogger(__name__)

router = APIRouter(tags=["configs"])


def generate_patches_handler(output_dir: Path) -> None:
    """Executes generate-patches script to render shared cluster manifests and patches."""
    gen_patches = settings.CONFIGS_DIR / "generate-patches" / "bin" / "generate-patches"
    if not gen_patches.exists():
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        res = subprocess.run(
            [str(gen_patches), str(output_dir)],
            capture_output=True,
            text=True,
            cwd=str(output_dir),
            timeout=15,
        )
    except Exception as e:
        logger.error(f"Failed executing generate-patches: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Config generation failed: {e}",
        )

    if res.returncode != 0:
        logger.error(f"generate-patches failed (exit {res.returncode}): {res.stderr}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Config generation failed: {res.stderr}",
        )


def generate_config_handler(conf_path: Path, output_dir: Path, secrets_file: Optional[str] = None) -> None:
    """Executes generate-config script for a target node configuration."""
    gen_bin = conf_path / "bin" / "generate-config"
    if not gen_bin.exists():
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Config generation failed: Config generator binary not found at {gen_bin}",
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    secrets_arg = (
        [secrets_file]
        if secrets_file and Path(secrets_file).exists()
        else []
    )

    try:
        res = subprocess.run(
            [str(gen_bin), str(output_dir)] + secrets_arg,
            capture_output=True,
            text=True,
            cwd=str(output_dir),
            timeout=30,
        )
    except Exception as e:
        logger.error(f"Failed executing generate-config: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Config generation failed: {e}",
        )

    if res.returncode != 0:
        logger.error(f"generate-config failed (exit {res.returncode}): {res.stderr}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Config generation failed: {res.stderr}",
        )

    for f in output_dir.glob("*"):
        try:
            f.chmod(0o644)
        except Exception as e:
            logger.warning(f"Failed to chmod file {f}: {e}")


@router.api_route("/configs/{conf_name}", methods=["GET", "HEAD"], summary="Generate and serve Talos node configurations or manifests")
def get_config(conf_name: str) -> Response:
    """Generates and serves Talos machine configuration or cluster manifest YAML dynamically."""
    is_age_req = conf_name.endswith(".age")
    target_conf = conf_name[:-4] if is_age_req else conf_name
    node_key = target_conf.replace(".yaml", "")

    conf_path = settings.CONFIGS_DIR / target_conf
    content: bytes | None = None

    # Check if requested config is a shared patch/manifest (e.g. cilium.yaml, cni.yaml)
    gen_patches = settings.CONFIGS_DIR / "generate-patches" / "bin" / "generate-patches"
    if not (conf_path.exists() and conf_path.is_dir() and (conf_path / "bin" / "generate-config").exists()):
        if gen_patches.exists():
            generate_patches_handler(settings.talos_dir)
            for candidate in [
                settings.talos_dir / target_conf,
                settings.talos_dir / "addons" / target_conf,
                settings.talos_dir / "base-patches" / target_conf,
            ]:
                if candidate.exists() and candidate.is_file():
                    content = candidate.read_bytes()
                    break

        if content is not None:
            return Response(content=content, media_type="application/yaml")

    # Declarative Gating: If the node is not declared in flake machines, reject with 404
    flake_machines = get_flake_machines()
    if not flake_machines or node_key not in flake_machines:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Machine '{node_key}' is not declared in cluster machines.",
        )

    if conf_path.exists() and conf_path.is_file():
        content = conf_path.read_bytes()
    elif conf_path.exists() and conf_path.is_dir() and (conf_path / "bin" / "generate-config").exists():
        if gen_patches.exists():
            generate_patches_handler(settings.talos_dir)

        generate_config_handler(conf_path, settings.talos_dir, settings.SECRETS_FILE)

        yaml_file = settings.talos_dir / target_conf
        if not yaml_file.exists():
            for alt in [
                settings.talos_dir / "controlplane.yaml",
                settings.talos_dir / "worker.yaml",
            ]:
                if alt.exists():
                    yaml_file = alt
                    break

        if yaml_file.exists():
            content = yaml_file.read_bytes()
        else:
            logger.error(f"Output config {yaml_file} not found after generation.")

    if content is not None:
        return Response(content=content, media_type="text/yaml")

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail=f"Config for '{target_conf}' could not be generated or found.",
    )

import re
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status

from coordinator.config import settings
from coordinator.api.deps import require_local_auth
from coordinator.schemas.status import ReportSummary, ReportsListResponse
from coordinator.services.state_store import (
    normalize_mac,
    format_mac,
    get_flake_machines,
    get_discovered_nodes,
    get_wipe_data,
    save_wipe_data,
    resolve_target_macs,
    save_inspector_report,
    prune_secondary_mac_keys,
)
from coordinator.services.hardware import compile_hardware_reports

router = APIRouter(tags=["reports"])


@router.get(
    "/api/reports",
    dependencies=[Depends(require_local_auth)],
    summary="List hardware inspector reports or fetch report for a node",
)
def get_reports(
    node: Optional[str] = Query(default=None, description="Target node name or MAC address"),
    hostname: Optional[str] = Query(default=None, description="Alternative target node name"),
) -> Response:
    """Returns inspector reports list or single node report YAML (Localhost / SSH only)."""
    target = node or hostname
    if target:
        flake_machines = get_flake_machines()
        discovered = get_discovered_nodes()
        target_macs = resolve_target_macs(target, flake_machines, discovered)
        clean_targets = [m.replace(":", "-") for m in target_macs] if target_macs else []
        clean_targets.append(
            target.replace(".yaml", "").replace("inspector-report-", "").replace(":", "-")
        )

        target_file = None
        for filepath in sorted(settings.inspector_dir.glob("*.yaml")):
            if "wipe-log" in filepath.name:
                continue
            if any(ct in filepath.name for ct in clean_targets if ct):
                target_file = filepath
                break

        if target_file and target_file.exists():
            return Response(
                content=target_file.read_text(encoding="utf-8", errors="replace"),
                media_type="text/yaml",
            )
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Inspector report not found for target '{target}'.",
        )

    reports: list[ReportSummary] = []
    if settings.inspector_dir.exists():
        for filepath in sorted(settings.inspector_dir.glob("*.yaml")):
            if "wipe-log" in filepath.name:
                continue
            reports.append(
                ReportSummary(
                    filename=filepath.name,
                    size_bytes=filepath.stat().st_size,
                    modified_at=filepath.stat().st_mtime,
                )
            )

    return Response(
        content=ReportsListResponse(count=len(reports), reports=reports).model_dump_json(indent=2),
        media_type="application/json",
    )


@router.post("/api/reports", summary="Receive hardware inspector report")
@router.post("/api/report", summary="Receive hardware inspector report (alias)")
async def post_report(
    request: Request,
    hostname: Optional[str] = Query(default=None),
) -> dict:
    """Receives and stores hardware inspection report from ephemeral Inspector RAMdisk."""
    body_bytes = await request.body()
    payload = body_bytes.decode("utf-8", errors="replace")

    req_hostname = "unknown"
    if hostname:
        req_hostname = hostname
    elif request.headers.get("x-hostname"):
        req_hostname = request.headers["x-hostname"]
    else:
        host_match = re.search(r"hostname:\s*[\"']?([a-zA-Z0-9_-]+)", payload)
        if host_match:
            req_hostname = host_match.group(1)

    macs = re.findall(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", payload)
    clean_macs = [normalize_mac(m) for m in macs]
    norm_req = normalize_mac(req_hostname)
    if norm_req and norm_req not in clean_macs:
        clean_macs.append(norm_req)

    pmac_match = re.search(r'primary_mac:\s*["\']?([0-9a-fA-F:]{17})["\']?', payload)
    reported_pmac = normalize_mac(pmac_match.group(1)) if pmac_match else None

    if reported_pmac:
        target_mac = format_mac(reported_pmac)
    elif clean_macs:
        target_mac = format_mac(clean_macs[0])
    else:
        target_mac = req_hostname

    report_path = save_inspector_report(target_mac, payload, req_hostname)

    try:
        compile_hardware_reports()
    except Exception as e:
        print(f"[WARN] Failed to auto-generate machines.nix: {e}", flush=True)

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    discovered_nodes = get_discovered_nodes()

    target_macs = resolve_target_macs(target_mac, flake_machines, discovered_nodes)
    canonical_mac = target_macs[0] if target_macs else target_mac

    prune_secondary_mac_keys(wipe_data, canonical_mac, flake_machines, discovered_nodes)

    wentry = wipe_data.get(canonical_mac, {})
    should_wipe = wentry.get("requested", False) or wentry.get("status") == "IN_PROGRESS"
    if should_wipe:
        wentry["status"] = "IN_PROGRESS"
        wipe_data[canonical_mac] = wentry
        save_wipe_data(wipe_data)

    print(f"[RECV] Saved report for {canonical_mac} (wipe={should_wipe})", flush=True)

    return {
        "status": "success",
        "filename": report_path.name,
        "mac": target_mac,
        "hostname": target_mac,
        "wipe": should_wipe,
    }

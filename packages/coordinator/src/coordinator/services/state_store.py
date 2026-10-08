import json
import logging
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional
from filelock import FileLock

from coordinator.config import settings

logger = logging.getLogger(__name__)


def normalize_mac(mac: Optional[str]) -> str:
    """Normalizes MAC address string to lowercase 12-char hex without colons or hyphens."""
    if not mac or not isinstance(mac, str):
        return ""
    return mac.lower().replace(":", "").replace("-", "").strip()


def format_mac(clean_mac: Optional[str]) -> str:
    """Formats a 12-char clean MAC into standard colon-separated lowercase format."""
    clean = normalize_mac(clean_mac)
    if len(clean) == 12:
        return ":".join(clean[i : i + 2] for i in range(0, 12, 2))
    return (clean_mac or "").lower().strip()


def atomic_save_text(path: Path, text: str) -> None:
    """Safely writes text to disk atomically using a temporary file."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=str(path.parent), delete=False
        ) as tf:
            tf.write(text)
            tmp_path = Path(tf.name)
        os.replace(tmp_path, path)
    except Exception as e:
        logger.error(f"Failed to atomically write {path}: {e}")
        raise


def atomic_save_json(path: Path, data: Any) -> None:
    """Safely writes JSON data to disk atomically using a temporary file."""
    atomic_save_text(path, json.dumps(data, indent=2))


def get_flake_machines() -> Dict[str, Any]:
    """Parses and returns declared machines from FLAKE_MACHINES_FILE or fallback to FLAKE_MACHINES_JSON."""
    file_path = settings.FLAKE_MACHINES_FILE
    if file_path and Path(file_path).exists():
        try:
            data = json.loads(Path(file_path).read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception as e:
            logger.warning(f"Failed to read FLAKE_MACHINES_FILE {file_path}: {e}")

    raw = settings.FLAKE_MACHINES_JSON or "{}"
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        logger.warning(f"Failed to parse FLAKE_MACHINES_JSON: {e}")
        return {}


def get_wipe_lock() -> FileLock:
    """Returns a FileLock instance guarding wipe.json."""
    settings.wipe_dir.mkdir(parents=True, exist_ok=True)
    lock_path = settings.wipe_dir / "wipe.json.lock"
    return FileLock(str(lock_path), timeout=10)


def get_wipe_data() -> Dict[str, Dict[str, Any]]:
    """Reads wipe.json from disk with process locking and returns clean dict keyed strictly by normalized MAC."""
    settings.ensure_directories()
    wipe_data: Dict[str, Dict[str, Any]] = {}

    with get_wipe_lock():
        if settings.wipe_file.exists():
            try:
                raw = json.loads(settings.wipe_file.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    for k, v in raw.items():
                        if isinstance(v, dict):
                            clean_k = normalize_mac(k)
                            if len(clean_k) == 12:
                                formatted_k = format_mac(clean_k)
                                wspec = (
                                    v.get("wipe", {})
                                    if isinstance(v.get("wipe"), dict)
                                    else v
                                )
                                wipe_data[formatted_k] = {
                                    "requested": bool(wspec.get("requested", False)),
                                    "status": str(wspec.get("status", "NONE")),
                                    "timestamp": wspec.get("timestamp"),
                                    "log": wspec.get("log"),
                                    "pxe_ip": v.get("pxe_ip") or wspec.get("pxe_ip"),
                                    "installed": bool(v.get("installed", False)),
                                    "installed_at": v.get("installed_at"),
                                }
            except Exception as e:
                logger.warning(f"Failed to parse wipe file {settings.wipe_file}: {e}")
    return wipe_data


def save_wipe_data(data: Dict[str, Any]) -> None:
    """Atomically writes wipe_data dict to WIPE_FILE guarded by FileLock."""
    settings.ensure_directories()
    with get_wipe_lock():
        atomic_save_json(settings.wipe_file, data)


def get_discovered_nodes() -> List[Dict[str, Any]]:
    """Parses all inspector reports in INSPECTOR_DIR to list discovered nodes."""
    nodes: List[Dict[str, Any]] = []
    seen_macs = set()
    if not settings.inspector_dir.exists():
        return nodes

    for report_path in sorted(settings.inspector_dir.glob("*.yaml")):
        if "wipe-log" in report_path.name:
            continue
        try:
            payload = report_path.read_text(encoding="utf-8")
            # 1. Extract reported primary_mac, primary_ip, and primary_iface
            pmac_match = re.search(r'primary_mac:\s*["\']?([0-9a-fA-F:]{17})["\']?', payload)
            reported_pmac = normalize_mac(pmac_match.group(1)) if pmac_match else None
            pip_match = re.search(r'primary_ip:\s*["\']?([0-9.]+)', payload)
            reported_pip = pip_match.group(1).strip() if pip_match else None
            pif_match = re.search(r'primary_iface:\s*["\']?([^\s"\']+)', payload)
            reported_pif = pif_match.group(1).strip() if pif_match else None

            # 2. Extract all MACs, filter loopback/null/broadcast, and deduplicate
            raw_macs = re.findall(r'(?:mac|address):\s*["\']?([0-9a-fA-F:]{17})["\']?', payload)
            clean_macs: List[str] = []
            for m in raw_macs:
                norm = normalize_mac(m)
                if norm and norm not in ("000000000000", "ffffffffffff") and norm not in clean_macs:
                    clean_macs.append(norm)

            if not clean_macs:
                continue

            if any(m in seen_macs for m in clean_macs):
                continue
            seen_macs.update(clean_macs)

            # 3. Determine primary MAC
            primary_clean = reported_pmac if reported_pmac in clean_macs else clean_macs[0]
            ordered_clean = [primary_clean] + [m for m in clean_macs if m != primary_clean]

            primary_mac = format_mac(primary_clean)
            mac_suffix = primary_clean[-6:] if len(primary_clean) >= 6 else "unknown"
            node_name = f"node-{mac_suffix}"
            nodes.append({
                "name": node_name,
                "primary_mac": primary_mac,
                "pxe_ip": reported_pip or "-",
                "iface": reported_pif or "-",
                "macs": [format_mac(m) for m in ordered_clean],
            })
        except Exception as e:
            logger.warning(f"Failed to parse inspector report {report_path}: {e}")
    return nodes


def resolve_target_macs(
    target: str, flake_machines: Dict[str, Any], discovered_nodes: List[Dict[str, Any]]
) -> List[str]:
    """
    Resolves a target name, 'all', or MAC address into a list of verified MAC strings.
    Strictly forbids blind operations on unverified arbitrary MACs.
    """
    target = (target or "").strip()
    if not target:
        return []

    # 1. Target "all": Collect all declared nodes in flake_machines, or all discovered nodes
    if target in ("all", "all_known"):
        resolved = []
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict):
                if fspec.get("macs"):
                    resolved.append(format_mac(fspec["macs"][0]))
                else:
                    net_ifaces = fspec.get("network-interfaces", {})
                    for attrs in net_ifaces.values():
                        if isinstance(attrs, dict) and attrs.get("mac"):
                            resolved.append(format_mac(attrs["mac"]))
                            break
        if not resolved:
            for d in discovered_nodes:
                resolved.append(d["primary_mac"])
        return list(set(resolved))

    # 2. Match declared flake machine name
    if target in flake_machines:
        fspec = flake_machines[target]
        if isinstance(fspec, dict):
            if fspec.get("macs"):
                return [format_mac(fspec["macs"][0])]
            net_ifaces = fspec.get("network-interfaces", {})
            for attrs in net_ifaces.values():
                if isinstance(attrs, dict) and attrs.get("mac"):
                    return [format_mac(attrs["mac"])]

    # 3. Match discovered node name (e.g. node-3302)
    for d in discovered_nodes:
        if d.get("name") == target:
            return [d["primary_mac"]]

    # 4. Match direct MAC (only if it belongs to a declared machine or discovered node)
    clean_target = normalize_mac(target)
    if len(clean_target) == 12:
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict):
                fmacs = [normalize_mac(m) for m in fspec.get("macs", [])]
                net_ifaces = fspec.get("network-interfaces", {})
                for attrs in net_ifaces.values():
                    if isinstance(attrs, dict) and attrs.get("mac"):
                        fmacs.append(normalize_mac(attrs["mac"]))
                if clean_target in fmacs:
                    if fspec.get("macs"):
                        return [format_mac(fspec["macs"][0])]
                    for attrs in net_ifaces.values():
                        if isinstance(attrs, dict) and attrs.get("mac"):
                            return [format_mac(attrs["mac"])]
        for d in discovered_nodes:
            dmacs = [normalize_mac(m) for m in d.get("macs", [])]
            if clean_target in dmacs:
                return [d["primary_mac"]]

    return []


def prune_secondary_mac_keys(
    wipe_data: Dict[str, Any],
    canonical_mac: str,
    flake_machines: Dict[str, Any],
    discovered_nodes: List[Dict[str, Any]],
) -> None:
    """Prunes non-canonical MAC keys belonging to the same physical node as canonical_mac."""
    clean_target = normalize_mac(canonical_mac)
    all_node_macs: List[str] = []
    for d in discovered_nodes:
        d_clean = [normalize_mac(m) for m in d.get("macs", [])]
        if clean_target in d_clean:
            all_node_macs = [format_mac(m) for m in d_clean]
            break
    if not all_node_macs and flake_machines:
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict):
                f_clean = [normalize_mac(m) for m in fspec.get("macs", [])]
                if clean_target in f_clean:
                    all_node_macs = [format_mac(m) for m in f_clean]
                    break
    for m in all_node_macs:
        if m != canonical_mac and m in wipe_data:
            del wipe_data[m]


def save_wipe_log(target_mac: str, payload: str, hostname: str = "") -> Path:
    """Saves a wipe log file to disk with timestamped filename and updates wipe state."""
    settings.wipe_logs_dir.mkdir(parents=True, exist_ok=True)
    now_dt = datetime.now(timezone.utc)
    iso_now = now_dt.isoformat()
    ts_str = now_dt.strftime("%Y%m%d-%H%M%S")

    clean_mac_name = target_mac.replace(":", "-")
    log_filename = f"wipe-{clean_mac_name}-{ts_str}.log"
    log_path = settings.wipe_logs_dir / log_filename
    atomic_save_text(log_path, payload)

    wipe_data = get_wipe_data()
    flake_machines = get_flake_machines()
    discovered_nodes = get_discovered_nodes()

    prune_secondary_mac_keys(wipe_data, target_mac, flake_machines, discovered_nodes)

    if target_mac not in wipe_data:
        wipe_data[target_mac] = {
            "requested": False,
            "status": "NONE",
            "timestamp": None,
            "log": None,
            "installed": False,
            "installed_at": None,
        }

    wipe_data[target_mac]["requested"] = False
    wipe_data[target_mac]["status"] = "SUCCESS"
    wipe_data[target_mac]["timestamp"] = iso_now
    wipe_data[target_mac]["log"] = str(log_path)
    wipe_data[target_mac]["installed"] = False

    save_wipe_data(wipe_data)
    logger.info(f"Saved wipe log for {target_mac} ({hostname}) to {log_path}")
    return log_path


def save_inspector_report(target_mac: str, payload: str, hostname: str = "") -> Path:
    """Saves an inspector report YAML file to disk and cleans up older duplicates."""
    settings.inspector_dir.mkdir(parents=True, exist_ok=True)
    clean_mac_name = target_mac.replace(":", "-")
    filename = f"inspector-report-{clean_mac_name}.yaml"
    filepath = settings.inspector_dir / filename
    atomic_save_text(filepath, payload)

    # Clean up older reports containing the same MACs
    macs = re.findall(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', payload)
    clean_macs = [normalize_mac(m) for m in macs]
    clean_mac_set = set(clean_macs)

    for old_path in settings.inspector_dir.glob("*.yaml"):
        if "wipe-log" in old_path.name or old_path.name == filename:
            continue
        for cm in clean_mac_set:
            if cm.replace(":", "-") in old_path.name:
                try:
                    old_path.unlink(missing_ok=True)
                except Exception as e:
                    logger.warning(f"Failed to remove obsolete inspector report {old_path}: {e}")
    return filepath


def purge_all_state() -> int:
    """Purges all inspector reports, wipe states, logs, and generated Talos state files."""
    count = 0
    if settings.inspector_dir.exists():
        for p in list(settings.inspector_dir.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception as e:
                logger.warning(f"Failed to remove inspector report {p}: {e}")
    if settings.wipe_logs_dir.exists():
        for p in list(settings.wipe_logs_dir.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception as e:
                logger.warning(f"Failed to remove wipe log {p}: {e}")
    if settings.wipe_file.exists():
        try:
            settings.wipe_file.unlink(missing_ok=True)
            count += 1
        except Exception as e:
            logger.warning(f"Failed to remove wipe file {settings.wipe_file}: {e}")
    if settings.talos_dir.exists():
        for p in list(settings.talos_dir.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception as e:
                logger.warning(f"Failed to remove talos file {p}: {e}")
    logger.info(f"Purged {count} coordinator state items.")
    return count

#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# ==============================================================================
# CONFIGURATION & PATH REGISTRY
# ==============================================================================
PORT = int(os.environ.get("PORT", "8080"))
COORDINATOR_ROOT = Path(os.environ.get("COORDINATOR_ROOT", "/var/lib/coordinator"))
INSPECTOR_DIR = Path(os.environ.get("INSPECTOR_DIR", COORDINATOR_ROOT / "inspector"))
TALOS_DIR = Path(os.environ.get("TALOS_DIR", COORDINATOR_ROOT / "talos"))
WIPE_DIR = Path(os.environ.get("WIPE_DIR", COORDINATOR_ROOT / "wipe"))
WIPE_LOGS_DIR = WIPE_DIR / "logs"
WIPE_FILE = WIPE_DIR / "wipe.json"
CONFIGS_DIR = Path(os.environ.get("CONFIGS_DIR", "/var/lib/tftpboot/configs"))
SECRETS_FILE = os.environ.get("SECRETS_FILE")

# Ensure required runtime directories exist
for d in [INSPECTOR_DIR, TALOS_DIR, WIPE_DIR, WIPE_LOGS_DIR]:
    try:
        d.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
def normalize_mac(mac: str) -> str:
    """Normalizes MAC address string to lowercase 12-char hex without colons or hyphens."""
    if not mac or not isinstance(mac, str):
        return ""
    return mac.lower().replace(":", "").replace("-", "")

def format_mac(clean_mac: str) -> str:
    """Formats a 12-char clean MAC into standard colon-separated lowercase format."""
    clean = normalize_mac(clean_mac)
    if len(clean) == 12:
        return ":".join(clean[i:i+2] for i in range(0, 12, 2))
    return clean_mac.lower() if clean_mac else ""

def atomic_save_text(path: Path, text: str):
    """Safely writes text to disk atomically using a temporary file."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_file = path.with_suffix(".tmp")
        tmp_file.write_text(text, encoding="utf-8")
        os.replace(tmp_file, path)
    except Exception as e:
        print(f"[ERROR] Failed to atomically write {path}: {e}", flush=True)

def atomic_save_json(path: Path, data: dict):
    """Safely writes JSON data to disk atomically using a temporary file."""
    try:
        atomic_save_text(path, json.dumps(data, indent=2))
    except Exception as e:
        print(f"[ERROR] Failed to atomically write JSON {path}: {e}", flush=True)

def get_flake_machines() -> dict:
    """Parses and returns declared machines from FLAKE_MACHINES_FILE or fallback to FLAKE_MACHINES_JSON."""
    file_path = os.environ.get("FLAKE_MACHINES_FILE")
    if file_path and Path(file_path).exists():
        try:
            data = json.loads(Path(file_path).read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception as e:
            print(f"[WARN] Failed to read FLAKE_MACHINES_FILE {file_path}: {e}", flush=True)

    raw = os.environ.get("FLAKE_MACHINES_JSON", "{}")
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception as e:
        print(f"[WARN] Failed to parse FLAKE_MACHINES_JSON: {e}", flush=True)
        return {}

def find_node_by_target(wipe_data: dict, target: str, flake_machines: dict = None) -> tuple:
    """
    Multi-key resolver: finds a node in wipe_data by name, primary MAC, secondary MAC, or IP.
    Returns (primary_mac_key, node_entry_dict) or (None, None).
    """
    if not target or not isinstance(wipe_data, dict):
        return None, None

    clean_target = normalize_mac(target)

    # 1. Direct primary MAC key match
    for k, v in wipe_data.items():
        if k.startswith("wipe_") or not isinstance(v, dict):
            continue
        if k == target or (clean_target and normalize_mac(k) == clean_target):
            return k, v

    # 2. Match by logical node name
    for k, v in wipe_data.items():
        if k.startswith("wipe_") or not isinstance(v, dict):
            continue
        if v.get("name") == target:
            return k, v

    # 3. Match by any secondary MAC or PXE IP
    for k, v in wipe_data.items():
        if k.startswith("wipe_") or not isinstance(v, dict):
            continue
        pmacs = [normalize_mac(m) for m in v.get("macs", []) if isinstance(m, str)]
        if clean_target and clean_target in pmacs:
            return k, v
        if v.get("pxe_ip") == target:
            return k, v

    # 4. Check Flake machines mapping
    if flake_machines is None:
        flake_machines = get_flake_machines()
    if flake_machines and target in flake_machines:
        fspec = flake_machines[target]
        fmacs = fspec.get("macs", [])
        if fmacs:
            pmac = format_mac(fmacs[0])
            if pmac in wipe_data:
                return pmac, wipe_data[pmac]

    return None, None

def sync_wipe_data_with_flake(wipe_data=None) -> dict:
    """
    Ensures wipe.json is keyed by canonical primary MAC.
    Migrates legacy name-keyed entries and merges Flake declared node specs.
    """
    flake_machines = get_flake_machines()

    if wipe_data is None:
        if WIPE_FILE.exists():
            try:
                wipe_data = json.loads(WIPE_FILE.read_text(encoding="utf-8"))
            except Exception:
                wipe_data = {"wipe_all_known": False}
        else:
            wipe_data = {"wipe_all_known": False}

    if not isinstance(wipe_data, dict):
        wipe_data = {"wipe_all_known": False}

    # Step 1: Migrate any legacy non-MAC keys in wipe_data
    migrated = {}
    for k, v in wipe_data.items():
        if k == "wipe_all_known":
            migrated[k] = v
            continue
        if not isinstance(v, dict):
            continue

        clean_k = normalize_mac(k)
        if len(clean_k) == 12:
            # Key is already a MAC
            formatted_k = format_mac(clean_k)
            migrated[formatted_k] = v
        else:
            # Key is a node name (e.g. "control", "worker1")
            node_name = k
            mac_list = v.get("macs", [])
            primary_mac = format_mac(mac_list[0]) if mac_list else ""
            if not primary_mac and node_name in flake_machines:
                fmacs = flake_machines[node_name].get("macs", [])
                if fmacs:
                    primary_mac = format_mac(fmacs[0])

            if primary_mac:
                v["name"] = node_name
                migrated[primary_mac] = v
            else:
                migrated[k] = v

    wipe_data = migrated

    # Step 2: Merge Flake-declared machines into MAC-keyed records
    for fname, fspec in flake_machines.items():
        if not isinstance(fspec, dict):
            continue
        fmacs = fspec.get("macs", [])
        if not fmacs:
            continue

        primary_mac = format_mac(fmacs[0])
        all_fmacs = [format_mac(m) for m in fmacs]

        if primary_mac not in wipe_data:
            wipe_data[primary_mac] = {
                "name": fname,
                "known": True,
                "macs": all_fmacs,
                "pxe_ip": None,
                "pxe_mac": primary_mac,
                "wipe": {
                    "requested": False,
                    "status": "NONE",
                    "timestamp": None,
                    "log": None,
                }
            }
        else:
            wipe_data[primary_mac]["name"] = fname
            wipe_data[primary_mac]["known"] = True
            if not wipe_data[primary_mac].get("macs"):
                wipe_data[primary_mac]["macs"] = all_fmacs

    return wipe_data

def get_wipe_data() -> dict:
    """Reads wipe.json from disk, synchronizes keys, and returns state dict."""
    wipe_data = {"wipe_all_known": False}
    if WIPE_FILE.exists():
        try:
            wipe_data = json.loads(WIPE_FILE.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[WARN] Failed to parse {WIPE_FILE}: {e}", flush=True)

    wipe_data = sync_wipe_data_with_flake(wipe_data)
    atomic_save_json(WIPE_FILE, wipe_data)
    return wipe_data

def save_wipe_data(data: dict):
    """Safely writes wipe_data dict to WIPE_FILE atomically."""
    atomic_save_json(WIPE_FILE, data)

# ==============================================================================
# DYNAMIC MACHINES.NIX GENERATOR
# ==============================================================================
def generate_machines_nix() -> bytes:
    """Dynamically compiles all saved YAML hardware reports in INSPECTOR_DIR into machines.nix."""
    nix_file = INSPECTOR_DIR / "machines.nix"
    nodes_json_file = INSPECTOR_DIR / "discovered-nodes.json"

    flake_machines = get_flake_machines()
    wipe_data = get_wipe_data()

    entries = []
    discovered_nodes_list = []
    seen_macs = set()

    for report_path in sorted(INSPECTOR_DIR.glob("*.yaml")):
        if "wipe-log" in report_path.name:
            continue
        try:
            payload = report_path.read_text(encoding="utf-8")

            # 1. Parse Network Devices
            devices = []
            net_match = re.search(r'network_devices:\s*\n([\s\S]*?)(?=\n\w+:|$)', payload)
            if net_match:
                devices = re.findall(r'name:\s*([^\s\n]+)[\s\S]*?mac_address:\s*([0-9a-fA-F:]{17})', net_match.group(1))

            if not devices:
                macs = re.findall(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', payload)
                devices = [(f"enp{idx+3}s0", m) for idx, m in enumerate(macs)]

            macs = [normalize_mac(d[1]) for d in devices]
            if not macs or macs[0] in seen_macs:
                continue
            seen_macs.add(macs[0])

            # 2. Match host against Flake-declared machines
            resolved_name = None
            is_control_plane = "false"

            for mac in macs:
                for name, spec in flake_machines.items():
                    if not isinstance(spec, dict):
                        continue
                    net_ifaces = spec.get("network-interfaces", {})
                    matched_macs = [normalize_mac(attrs.get("mac", "")) for attrs in net_ifaces.values() if isinstance(attrs, dict)]
                    if not matched_macs:
                        matched_macs = [normalize_mac(m) for m in spec.get("macs", []) if isinstance(m, str)]
                    if mac in matched_macs:
                        resolved_name = name
                        if spec.get("controlPlane", False):
                            is_control_plane = "true"
                        break
                if resolved_name:
                    break

            if not resolved_name:
                mac_suffix = macs[0][-6:] if len(macs[0]) >= 6 else "unknown"
                resolved_name = f"node-{mac_suffix}"

            # 3. Parse active IPs and primary interface reported by Inspector
            ip_map = {}
            primary_iface_reported = ""
            primary_mac_reported = ""

            net_header = re.search(r'network:\s*\n([\s\S]*?)(?=\n\w+:|$)', payload)
            if net_header:
                pif_m = re.search(r'primary_iface:\s*([^\s\n]+)', net_header.group(1))
                pmac_m = re.search(r'primary_mac:\s*([^\s\n]+)', net_header.group(1))
                if pif_m:
                    primary_iface_reported = pif_m.group(1).strip()
                if pmac_m:
                    primary_mac_reported = normalize_mac(pmac_m.group(1).strip())

                ifaces_m = re.search(r'interfaces:\s*\n([\s\S]*?)(?=\n\w+:|$)', net_header.group(1))
                if ifaces_m:
                    blocks = re.findall(r'-\s+iface:\s*([^\s\n]+)[\s\S]*?mac:\s*([^\s\n]*)[\s\S]*?ips:\s*([^\s\n]*)', ifaces_m.group(1))
                    for ifname, ifmac, ifips in blocks:
                        cleaned_ips = [ip.strip() for ip in ifips.split(",") if ip.strip()]
                        ip_map[ifname] = cleaned_ips
                        if ifmac:
                            ip_map[normalize_mac(ifmac)] = cleaned_ips

            # 4. Check active PXE MAC recorded during boot
            pmac_key, node_wdata = find_node_by_target(wipe_data, resolved_name, flake_machines)
            target_pxe_mac = normalize_mac(node_wdata.get("pxe_mac", "")) if isinstance(node_wdata, dict) else None

            def get_subnet_prefix(env_var: str) -> str:
                subnet = os.environ.get(env_var, "")
                if subnet and "/" in subnet:
                    return ".".join(subnet.split("/")[0].split(".")[:3]) + "."
                return ""

            private_prefix = get_subnet_prefix("PRIVATE_SUBNET")
            public_prefix = get_subnet_prefix("PUBLIC_SUBNET")

            # Determine the single canonical primary interface
            # Priority: 1) Active IP on private subnet, 2) Inspector reported primary_mac/primary_iface, 3) PXE boot MAC, 4) First enumerated device
            chosen_primary_iface = None
            for iface_name, mac in devices:
                clean_mac = normalize_mac(mac)
                iface_ips = ip_map.get(iface_name, []) + ip_map.get(clean_mac, [])
                if any(ip.startswith(private_prefix) for ip in iface_ips) if private_prefix else False:
                    chosen_primary_iface = iface_name
                    break

            if not chosen_primary_iface and (primary_mac_reported or primary_iface_reported):
                for iface_name, mac in devices:
                    clean_mac = normalize_mac(mac)
                    if (primary_mac_reported and clean_mac == primary_mac_reported) or (primary_iface_reported and iface_name == primary_iface_reported):
                        chosen_primary_iface = iface_name
                        break

            if not chosen_primary_iface and target_pxe_mac:
                for iface_name, mac in devices:
                    clean_mac = normalize_mac(mac)
                    if clean_mac == target_pxe_mac:
                        chosen_primary_iface = iface_name
                        break

            if not chosen_primary_iface and devices:
                chosen_primary_iface = devices[0][0]

            iface_lines = []
            for idx, (iface_name, mac) in enumerate(devices):
                clean_mac = normalize_mac(mac)
                formatted_mac = format_mac(clean_mac)
                iface_ips = ip_map.get(iface_name, []) + ip_map.get(clean_mac, [])
                is_public = any(ip.startswith(public_prefix) for ip in iface_ips) if public_prefix else False

                if iface_name == chosen_primary_iface:
                    role = "private"
                    primary = "true"
                else:
                    role = "public"
                    primary = "false"

                iface_lines.append(f"      {iface_name} = {{\n        mac = \"{formatted_mac}\";\n        role = \"{role}\";\n        primary = {primary};\n      }};")

            # 5. Check NVIDIA GPU presence
            has_nvidia = any(k in payload.lower() for k in ["nvidia", "geforce", "rtx", "cuda", "tesla", "a100", "h100"])
            nvidia_val = "true" if has_nvidia else "false"

            # 6. Parse Block Devices
            block_devs = []
            blk_match = re.search(r'block_devices:\s*\n([\s\S]*?)(?=\n\w+:|$)', payload)
            if blk_match:
                raw_items = re.split(r'\n(?=-\s+name:)', "\n" + blk_match.group(1))
                for item in raw_items:
                    name_m = re.search(r'name:\s*([^\s\n]+)', item)
                    size_m = re.search(r'size_bytes:\s*([0-9]+)', item)
                    by_id_m = re.search(r'by_id:\s*([^\s\n]+)', item)
                    model_m = re.search(r'model:\s*(?:["\']?([^"\'\n]+)["\']?)', item)
                    tran_m = re.search(r'transport:\s*([^\s\n]+)', item)
                    if name_m and size_m:
                        block_devs.append({
                            "name": name_m.group(1).strip(),
                            "size_bytes": int(size_m.group(1)),
                            "by_id": by_id_m.group(1).strip() if by_id_m and by_id_m.group(1) != "null" else "",
                            "model": model_m.group(1).strip() if model_m and model_m.group(1) != "null" else "",
                            "transport": tran_m.group(1).strip() if tran_m and tran_m.group(1) != "null" else ""
                        })

            # Sort: smaller drives first, NVMe preferred over SATA, alphabetical tie-breaker
            block_devs.sort(key=lambda d: (d["size_bytes"], 0 if d["transport"] == "nvme" else 1, d["name"]))

            if block_devs:
                os_dev = block_devs[0]
                os_path = os_dev["by_id"] if os_dev["by_id"] else f"/dev/{os_dev['name']}"
                disk_lines = [f'    osDisk = "{os_path}";']
                if len(block_devs) > 1:
                    disk_lines.append("    # Discovered secondary storage disks (unpartitioned for Kubernetes storage):")
                    for sdev in block_devs[1:]:
                        spath = sdev["by_id"] if sdev["by_id"] else f"/dev/{sdev['name']}"
                        s_gb = sdev["size_bytes"] / (1024**3)
                        model_str = f" ({sdev['model']})" if sdev["model"] else ""
                        disk_lines.append(f"    # - {spath} ({s_gb:.1f} GB{model_str})")
                disk_block = "\n".join(disk_lines)
            else:
                disk_block = '    osDisk = "/dev/nvme0n1";'

            ifaces_body = "\n".join(iface_lines)
            entry = f"""  {resolved_name} = {{
    controlPlane = {is_control_plane};
{disk_block}
    nvidia = {nvidia_val};
    network-interfaces = {{
{ifaces_body}
    }};
  }};"""
            entries.append(entry)
            discovered_nodes_list.append({
                "name": resolved_name,
                "controlPlane": is_control_plane == "true",
                "nvidia": has_nvidia,
                "macs": [format_mac(m) for m in macs],
            })
        except Exception as e:
            print(f"[WARN] Failed to parse report {report_path}: {e}", flush=True)

    content = "# Auto-generated discovered cluster machines definition\n# Generated by Inspector & Coordinator (imported by cluster.nix via `machines = import ./machines.nix;`):\n{\n" + "\n\n".join(entries) + "\n}\n"
    atomic_save_text(nix_file, content)
    atomic_save_json(nodes_json_file, {"nodes": discovered_nodes_list})
    return content.encode("utf-8")

# ==============================================================================
# UNIFIED HTTP REQUEST HANDLER
# ==============================================================================
class CoordinatorHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}", flush=True)

    def _send_json(self, status_code: int, data: dict):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, status_code: int, text: str, content_type: str = "text/plain"):
        body = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "healthy", "service": "coordinator"})
            return

        if self.path.startswith("/api/wipelog"):
            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            target = query_params.get("node", query_params.get("hostname", [""]))[0]
            wipe_data = get_wipe_data()
            flake_machines = get_flake_machines()

            log_path = None
            pmac_key, entry = find_node_by_target(wipe_data, target, flake_machines)
            if entry and entry.get("wipe", {}).get("log"):
                log_path = entry["wipe"]["log"]
            elif pmac_key:
                clean_mac = pmac_key.replace(":", "-")
                for p in sorted(WIPE_LOGS_DIR.glob(f"*{clean_mac}*.log"), reverse=True):
                    log_path = str(p)
                    break

            if not log_path and target:
                clean_t = target.replace(":", "-")
                for p in sorted(WIPE_LOGS_DIR.glob(f"*{clean_t}*.log"), reverse=True):
                    log_path = str(p)
                    break

            if log_path and Path(log_path).exists():
                self._send_text(200, Path(log_path).read_text(encoding="utf-8", errors="replace"))
            else:
                self._send_json(404, {"error": "Wipe log not found", "target": target})
            return

        if self.path in ("/api/status", "/api/wipe"):
            self._handle_api_status()
            return

        if self.path.startswith("/boot.ipxe"):
            self._handle_boot_ipxe()
            return

        if self.path.startswith("/configs/"):
            self._handle_configs()
            return

        if self.path.startswith("/api/reports"):
            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            target = query_params.get("node", query_params.get("hostname", [""]))[0]
            if not target:
                subpath = parsed_url.path.replace("/api/reports", "").strip("/")
                if subpath:
                    target = subpath

            if target:
                wipe_data = get_wipe_data()
                flake_machines = get_flake_machines()
                pmac_key, entry = find_node_by_target(wipe_data, target, flake_machines)

                target_file = None
                if pmac_key:
                    clean_mac = pmac_key.replace(":", "-")
                    for filepath in sorted(INSPECTOR_DIR.glob("*.yaml")):
                        if "wipe-log" in filepath.name:
                            continue
                        if clean_mac in filepath.name:
                            target_file = filepath
                            break

                if not target_file:
                    clean_t = target.replace(".yaml", "").replace("inspector-report-", "").replace(":", "-")
                    for filepath in sorted(INSPECTOR_DIR.glob("*.yaml")):
                        if "wipe-log" in filepath.name:
                            continue
                        if clean_t in filepath.name:
                            target_file = filepath
                            break

                if target_file and target_file.exists():
                    self._send_text(200, target_file.read_text(encoding="utf-8", errors="replace"), content_type="text/yaml")
                    return
                else:
                    self._send_json(404, {"error": "Report not found", "target": target})
                    return

            reports = []
            for filepath in sorted(INSPECTOR_DIR.glob("*.yaml")):
                if "wipe-log" in filepath.name:
                    continue
                reports.append({
                    "filename": filepath.name,
                    "size_bytes": filepath.stat().st_size,
                    "modified_at": filepath.stat().st_mtime
                })
            self._send_json(200, {"count": len(reports), "reports": reports})
            return

        if self.path in ("/api/discovered/machines.nix", "/api/discovered/nix"):
            content = generate_machines_nix()
            self._send_text(200, content.decode("utf-8"))
            return

        if self.path == "/api/discovered":
            disc_json = INSPECTOR_DIR / "discovered-nodes.json"
            if disc_json.exists():
                try:
                    self._send_json(200, json.loads(disc_json.read_text(encoding="utf-8")))
                    return
                except Exception:
                    pass
            self._send_json(200, {"nodes": []})
            return

        if self.path == "/api/purge":
            self._handle_purge()
            return

        self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path == "/api/wipe":
            self._handle_post_wipe()
            return

        if self.path == "/api/purge":
            self._handle_purge()
            return

        if self.path.startswith("/api/wipelog") or "wipelog" in self.path:
            self._handle_wipelog()
            return

        if self.path.startswith("/api/reports"):
            self._handle_reports()
            return

        self._send_json(404, {"error": "Not Found"})

    def _handle_purge(self):
        """Purges all inspector reports, wipe states, logs, and generated Talos state files."""
        count = 0
        for p in list(INSPECTOR_DIR.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception:
                pass
        for p in list(WIPE_LOGS_DIR.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception:
                pass
        if WIPE_FILE.exists():
            try:
                WIPE_FILE.unlink(missing_ok=True)
                count += 1
            except Exception:
                pass
        for p in list(TALOS_DIR.glob("*")):
            try:
                p.unlink(missing_ok=True)
                count += 1
            except Exception:
                pass
        print(f"[PURGE] Purged {count} coordinator state items.", flush=True)
        self._send_json(200, {
            "status": "PURGED",
            "purged_items": count,
            "message": "All coordinator reports, wipe logs, and state files cleared."
        })

    def _handle_api_status(self):
        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()
        self._send_json(200, {
            "coordinator_host": os.environ.get("HOSTNAME", "coordinator"),
            "dns_ip": os.environ.get("DNS_IP", "127.0.0.1"),
            "gateway_ip": os.environ.get("GATEWAY_IP", "127.0.0.1"),
            "private_subnet": os.environ.get("PRIVATE_SUBNET", ""),
            "public_subnet": os.environ.get("PUBLIC_SUBNET", ""),
            "flake_machines": list(flake_machines.keys()),
            "flake_specs": flake_machines,
            "wipe_data": wipe_data
        })

    def _handle_post_wipe(self):
        """Allows toggling wipe requests via POST /api/wipe (Localhost / SSH-authenticated only)."""
        client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else ""
        if client_ip not in ("127.0.0.1", "::1", "localhost"):
            print(f"[SECURITY] Blocked remote /api/wipe request from unauthorized IP: {client_ip}", flush=True)
            self._send_json(403, {
                "error": "Forbidden",
                "message": "Destructive wipe operations must originate from localhost via an SSH agent-authenticated session."
            })
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            req = json.loads(body)
        except Exception:
            req = {}

        target = req.get("target", "all")
        requested = req.get("requested", None)
        explicit_status = req.get("status", None)
        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()
        iso_now = datetime.now(timezone.utc).isoformat()

        if target in ("all", "all_known"):
            if requested is not None:
                wipe_data["wipe_all_known"] = requested
            for k, v in wipe_data.items():
                if k.startswith("wipe_") or not isinstance(v, dict):
                    continue
                if "wipe" not in v or not isinstance(v["wipe"], dict):
                    v["wipe"] = {}
                if requested is not None:
                    v["wipe"]["requested"] = requested
                if explicit_status:
                    v["wipe"]["status"] = explicit_status
                else:
                    v["wipe"]["status"] = "PENDING" if (requested if requested is not None else False) else "NONE"
                v["wipe"]["timestamp"] = iso_now
        else:
            pmac_key, entry = find_node_by_target(wipe_data, target, flake_machines)
            if pmac_key and entry:
                if "wipe" not in entry or not isinstance(entry["wipe"], dict):
                    entry["wipe"] = {}
                if requested is not None:
                    entry["wipe"]["requested"] = requested
                if explicit_status:
                    entry["wipe"]["status"] = explicit_status
                else:
                    entry["wipe"]["status"] = "PENDING" if (requested if requested is not None else False) else "NONE"
                entry["wipe"]["timestamp"] = iso_now
            elif normalize_mac(target):
                f_mac = format_mac(target)
                wipe_data[f_mac] = {
                    "name": None,
                    "known": False,
                    "macs": [f_mac],
                    "wipe": {
                        "requested": requested if requested is not None else False,
                        "status": explicit_status or ("PENDING" if requested else "NONE"),
                        "timestamp": iso_now,
                        "log": None,
                    }
                }

        save_wipe_data(wipe_data)
        self._send_json(200, {"status": "success", "target": target, "wipe_requested": requested, "node_status": explicit_status})

    def _handle_boot_ipxe(self):
        parsed_url = urlparse(self.path)
        query_params = parse_qs(parsed_url.query)
        mac = query_params.get("mac", [""])[0].lower()
        clean_req_mac = normalize_mac(mac)
        formatted_req_mac = format_mac(clean_req_mac)

        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()
        iso_now = datetime.now(timezone.utc).isoformat()
        client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else None

        # Resolve node identity in MAC-keyed wipe_data
        pmac_key, node_entry = find_node_by_target(wipe_data, mac, flake_machines)

        if not pmac_key:
            pmac_key = formatted_req_mac
            node_entry = {
                "name": None,
                "known": False,
                "discovered": iso_now,
                "macs": [formatted_req_mac],
                "pxe_ip": client_ip,
                "pxe_mac": formatted_req_mac,
                "wipe": {
                    "requested": False,
                    "status": "NONE",
                    "timestamp": None,
                    "log": None,
                }
            }
            wipe_data[pmac_key] = node_entry
        else:
            node_entry["pxe_ip"] = client_ip or node_entry.get("pxe_ip")
            node_entry["pxe_mac"] = formatted_req_mac

        # Determine node declared name
        name = node_entry.get("name")
        if not name and flake_machines:
            for fname, fspec in flake_machines.items():
                if not isinstance(fspec, dict):
                    continue
                fmacs = [normalize_mac(m) for m in fspec.get("macs", [])]
                if clean_req_mac in fmacs:
                    name = fname
                    node_entry["name"] = fname
                    node_entry["known"] = True
                    break

        if not name:
            mac_suffix = clean_req_mac[-6:] if clean_req_mac else "unknown"
            name = f"node-{mac_suffix}"

        # Check wipe request
        wspec = node_entry.get("wipe", {}) if isinstance(node_entry.get("wipe"), dict) else {}
        should_wipe = bool(wspec.get("requested") or wspec.get("status") == "IN_PROGRESS" or wipe_data.get("wipe_all_known"))

        dns_ip_env = os.environ.get("DNS_IP", "127.0.0.1")
        host_header = self.headers.get("Host", dns_ip_env)
        server_ip = host_header.split(":")[0] if host_header else dns_ip_env
        vmlinuz_path = Path("/var/lib/tftpboot") / name / "vmlinuz"

        if should_wipe:
            node_entry["wipe"]["status"] = "IN_PROGRESS"
            node_entry["wipe"]["timestamp"] = iso_now
            save_wipe_data(wipe_data)

            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  STORAGE WIPE | WIPING STORAGE DISKS ({name})
echo ========================================================================
echo   MAC Address : {formatted_req_mac}
echo   Action      : STORAGE WIPE REQUESTED
echo   Status      : IN_PROGRESS (READ-WRITE WIPE RAMDISK LOADING)
echo ========================================================================
echo
sleep 3
set cmdline coordinator.server=http://{server_ip}:{PORT} inspector.server=http://{server_ip}:{PORT} inspector.wipe=1
chain http://{server_ip}/default/netboot.ipxe
"""
        elif not node_entry.get("known") or not vmlinuz_path.exists():
            save_wipe_data(wipe_data)
            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  HARDWARE DISCOVERY | UNKNOWN NODE REPORTING ({name})
echo ========================================================================
echo   MAC Address : {formatted_req_mac}
echo   Status      : UNKNOWN (MAC NOT DECLARED IN MACHINES.NIX)
echo   Safety      : READ-ONLY HARDWARE REPORTING (DISKS SAFE)
echo ========================================================================
echo
sleep 2
set cmdline coordinator.server=http://{server_ip}:{PORT} inspector.server=http://{server_ip}:{PORT} inspector.wipe=0
chain http://{server_ip}/default/netboot.ipxe
"""
        else:
            save_wipe_data(wipe_data)
            node_role = "WORKER"
            is_nvidia = False
            f_spec = flake_machines.get(name, {})
            if isinstance(f_spec, dict):
                if f_spec.get("controlPlane"):
                    node_role = "CONTROL PLANE"
                is_nvidia = f_spec.get("nvidia", False)

            role_desc = f"{node_role} (nvidia = true)" if is_nvidia else node_role
            ramdisk_desc = "TALOS OS + NVIDIA GPU DRIVERS (506 MB)" if is_nvidia else "TALOS OS KERNEL & INITRAMFS (103 MB)"
            config_url = f"http://{server_ip}:{PORT}/configs/{name}.yaml"

            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  TALOS OS | BARE-METAL KUBERNETES BOOT ({name})
echo ========================================================================
echo   Role        : {role_desc}
echo   MAC Address : {formatted_req_mac}
echo   RAMDisk     : {ramdisk_desc}
echo   Config URI  : {config_url}
echo ========================================================================
echo
sleep 1
:boot_loop
kernel http://{server_ip}/{name}/vmlinuz talos.config={config_url} talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1 || goto boot_retry
initrd http://{server_ip}/{name}/initrd || goto boot_retry
boot || goto boot_retry

:boot_retry
echo Network transfer interrupted. Retrying in 2 seconds...
sleep 2
goto boot_loop
"""

        self._send_text(200, ipxe_script)

    def _handle_configs(self):
        conf_name = os.path.basename(self.path)
        conf_path = CONFIGS_DIR / conf_name
        content = None

        if conf_name == "talosconfig" and (TALOS_DIR / "talosconfig").exists():
            content = (TALOS_DIR / "talosconfig").read_bytes()

        if conf_path.exists() and conf_path.is_file():
            content = conf_path.read_bytes()
        elif conf_path.exists() and conf_path.is_dir() and (conf_path / "bin" / "generate-config").exists():
            try:
                TALOS_DIR.mkdir(parents=True, exist_ok=True)
            except Exception:
                pass

            gen_patches = CONFIGS_DIR / "generate-patches" / "bin" / "generate-patches"
            if gen_patches.exists():
                subprocess.run([str(gen_patches), str(TALOS_DIR)], capture_output=True, text=True, cwd=str(TALOS_DIR))

            secrets_arg = [SECRETS_FILE] if SECRETS_FILE and Path(SECRETS_FILE).exists() else []
            gen_bin = conf_path / "bin" / "generate-config"
            res = subprocess.run([str(gen_bin), str(TALOS_DIR)] + secrets_arg, capture_output=True, text=True, cwd=str(TALOS_DIR))

            if res.returncode != 0:
                print(f"[ERROR] generate-config failed for {conf_name} ({res.returncode}):\n{res.stderr}", flush=True)
                err_msg = f"# ERROR: generate-config failed for {conf_name}\n# Exit code: {res.returncode}\n\n{res.stderr}".encode("utf-8")
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(err_msg)))
                self.end_headers()
                self.wfile.write(err_msg)
                return

            for f in TALOS_DIR.glob("*"):
                try:
                    f.chmod(0o644)
                except Exception:
                    pass

            yaml_file = TALOS_DIR / conf_name
            if not yaml_file.exists():
                for alt in [TALOS_DIR / "controlplane.yaml", TALOS_DIR / "worker.yaml"]:
                    if alt.exists():
                        yaml_file = alt
                        break

            if yaml_file.exists():
                content = yaml_file.read_bytes()
            else:
                print(f"[ERROR] Output config {yaml_file} not found: {res.stderr}", flush=True)
        else:
            gen_patches = CONFIGS_DIR / "generate-patches" / "bin" / "generate-patches"
            if gen_patches.exists():
                with tempfile.TemporaryDirectory() as tmpdir:
                    subprocess.run([str(gen_patches), tmpdir], capture_output=True, text=True, cwd=tmpdir)
                    patch_file = Path(tmpdir) / conf_name
                    if patch_file.exists():
                        content = patch_file.read_bytes()

        if content is not None:
            client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else None
            node_key = conf_name.replace('.yaml', '')
            if client_ip and node_key and not client_ip.startswith("100.") and client_ip not in ("127.0.0.1", "::1", "localhost"):
                wd = get_wipe_data()
                pmac, entry = find_node_by_target(wd, node_key)
                if pmac and entry:
                    if entry.get("pxe_ip") != client_ip:
                        entry["pxe_ip"] = client_ip
                        save_wipe_data(wd)

            self.send_response(200)
            self.send_header("Content-Type", "text/yaml")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        self._send_json(404, {"error": "Not Found"})

    def _handle_wipelog(self):
        content_length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(content_length).decode("utf-8", errors="replace")

        parsed_url = urlparse(self.path)
        query_params = parse_qs(parsed_url.query)
        hostname = query_params.get("hostname", [self.headers.get("X-Hostname", "unknown")])[0]

        WIPE_LOGS_DIR.mkdir(parents=True, exist_ok=True)
        now_dt = datetime.now(timezone.utc)
        iso_now = now_dt.isoformat()
        ts_str = now_dt.strftime("%Y%m%d-%H%M%S")

        macs = re.findall(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', payload)
        clean_macs = [normalize_mac(m) for m in macs]
        req_mac = normalize_mac(hostname)
        if req_mac and req_mac not in clean_macs:
            clean_macs.append(req_mac)

        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()

        target_mac = None
        for m in clean_macs:
            pmac, entry = find_node_by_target(wipe_data, m, flake_machines)
            if pmac:
                target_mac = pmac
                break

        if not target_mac:
            target_mac = format_mac(clean_macs[0]) if clean_macs else hostname

        log_filename = f"wipe-{target_mac.replace(':', '-')}-{ts_str}.log"
        log_path = WIPE_LOGS_DIR / log_filename
        atomic_save_text(log_path, payload)

        if target_mac in wipe_data and isinstance(wipe_data[target_mac], dict):
            node_entry = wipe_data[target_mac]
            if "wipe" not in node_entry or not isinstance(node_entry["wipe"], dict):
                node_entry["wipe"] = {}
            node_entry["wipe"]["requested"] = False
            node_entry["wipe"]["status"] = "SUCCESS"
            node_entry["wipe"]["timestamp"] = iso_now
            node_entry["wipe"]["log"] = str(log_path)
            save_wipe_data(wipe_data)
            print(f"[WIPE] Updated {target_mac} ({node_entry.get('name')}) wipe status to SUCCESS in wipe.json", flush=True)

        print(f"[RECV] Saved wipe log to {log_path} for {target_mac}", flush=True)
        self._send_json(200, {"status": "success", "log": str(log_path), "mac": target_mac})

    def _handle_reports(self):
        content_length = int(self.headers.get("Content-Length", 0))
        payload = self.rfile.read(content_length).decode("utf-8", errors="replace")

        parsed_url = urlparse(self.path)
        query_params = parse_qs(parsed_url.query)

        hostname = "unknown"
        if "hostname" in query_params:
            hostname = query_params["hostname"][0]
        elif self.headers.get("X-Hostname"):
            hostname = self.headers.get("X-Hostname")
        else:
            match = re.search(r"inspector-report-([a-zA-Z0-9_-]+)", self.path)
            if match:
                hostname = match.group(1)
            else:
                host_match = re.search(r"hostname:\s*[\"']?([a-zA-Z0-9_-]+)", payload)
                if host_match:
                    hostname = host_match.group(1)

        macs = re.findall(r'([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})', payload)
        clean_macs = [normalize_mac(m) for m in macs]
        req_mac = normalize_mac(hostname)
        if req_mac and req_mac not in clean_macs:
            clean_macs.append(req_mac)

        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()

        target_mac = None
        for m in clean_macs:
            pmac, entry = find_node_by_target(wipe_data, m, flake_machines)
            if pmac:
                target_mac = pmac
                break

        if not target_mac:
            target_mac = format_mac(clean_macs[0]) if clean_macs else hostname

        filename = f"inspector-report-{target_mac.replace(':', '-')}.yaml"
        filepath = INSPECTOR_DIR / filename
        atomic_save_text(filepath, payload)

        try:
            generate_machines_nix()
        except Exception as e:
            print(f"[WARN] Failed to auto-generate machines.nix: {e}", flush=True)

        wipe_data = get_wipe_data()
        node_spec = wipe_data.get(target_mac, {})
        client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else None

        if isinstance(node_spec, dict):
            if client_ip:
                node_spec["pxe_ip"] = client_ip
            if clean_macs:
                node_spec["macs"] = [format_mac(m) for m in clean_macs]

        should_wipe = False
        if isinstance(node_spec, dict):
            wspec = node_spec.get("wipe", {}) if isinstance(node_spec.get("wipe"), dict) else {}
            if wspec.get("requested", False) or wspec.get("status") == "IN_PROGRESS" or wipe_data.get("wipe_all_known"):
                should_wipe = True
                wspec["status"] = "IN_PROGRESS"
                save_wipe_data(wipe_data)

        print(f"[RECV] Saved report for {target_mac} ({node_spec.get('name')}, wipe={should_wipe})", flush=True)

        self._send_json(200, {
            "status": "success",
            "filename": filename,
            "mac": target_mac,
            "hostname": target_mac,
            "wipe": should_wipe
        })

def run():
    get_wipe_data()
    server_address = ("", PORT)
    httpd = ThreadingHTTPServer(server_address, CoordinatorHandler)
    print(f"AI Village Cluster Coordinator running on port {PORT} (multithreaded)...", flush=True)
    print(f"Configs: {CONFIGS_DIR.resolve()} | State: {COORDINATOR_ROOT.resolve()}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nCoordinator shutting down.", flush=True)

if __name__ == "__main__":
    run()

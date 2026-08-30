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
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=str(path.parent), delete=False) as tf:
            tf.write(text)
            tmp_path = Path(tf.name)
        os.replace(tmp_path, path)
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

def get_wipe_data() -> dict:
    """Reads wipe.json from disk and returns clean dict keyed strictly by normalized MAC."""
    wipe_data = {}
    if WIPE_FILE.exists():
        try:
            raw = json.loads(WIPE_FILE.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                for k, v in raw.items():
                    if isinstance(v, dict):
                        clean_k = normalize_mac(k)
                        if len(clean_k) == 12:
                            formatted_k = format_mac(clean_k)
                            # Handle both flat and nested wipe structures
                            wspec = v.get("wipe", {}) if isinstance(v.get("wipe"), dict) else v
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
            print(f"[WARN] Failed to parse {WIPE_FILE}: {e}", flush=True)
    return wipe_data

def save_wipe_data(data: dict):
    """Atomically writes wipe_data dict to WIPE_FILE."""
    atomic_save_json(WIPE_FILE, data)

def get_discovered_nodes() -> list:
    """Parses all inspector reports in INSPECTOR_DIR to list discovered nodes."""
    nodes = []
    seen_macs = set()
    for report_path in sorted(INSPECTOR_DIR.glob("*.yaml")):
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
            clean_macs = []
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
            # Ensure primary MAC is at the head of the list
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
        except Exception:
            pass
    return nodes

def resolve_target_macs(target: str, flake_machines: dict, discovered_nodes: list) -> list:
    """
    Resolves a target name, 'all', or MAC address into a list of verified MAC strings.
    Strictly forbids blind wipes on unverified arbitrary MACs.
    """
    target = (target or "").strip()
    if not target:
        return []

    # 1. Target "all": Collect all declared nodes in flake_machines, or all discovered nodes
    if target in ("all", "all_known"):
        resolved = []
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict) and fspec.get("macs"):
                resolved.append(format_mac(fspec["macs"][0]))
        if not resolved:
            for d in discovered_nodes:
                resolved.append(d["primary_mac"])
        return list(set(resolved))

    # 2. Match declared flake machine name
    if target in flake_machines:
        fspec = flake_machines[target]
        if isinstance(fspec, dict) and fspec.get("macs"):
            return [format_mac(fspec["macs"][0])]

    # 3. Match discovered node name (e.g. node-3302)
    for d in discovered_nodes:
        if d["name"] == target:
            return [d["primary_mac"]]

    # 4. Match direct MAC (only if it belongs to a declared machine or discovered node)
    clean_target = normalize_mac(target)
    if len(clean_target) == 12:
        for fname, fspec in flake_machines.items():
            if isinstance(fspec, dict):
                fmacs = [normalize_mac(m) for m in fspec.get("macs", [])]
                if clean_target in fmacs:
                    return [format_mac(fspec["macs"][0])]
        for d in discovered_nodes:
            dmacs = [normalize_mac(m) for m in d.get("macs", [])]
            if clean_target in dmacs:
                return [d["primary_mac"]]

    return []

def prune_secondary_mac_keys(wipe_data: dict, canonical_mac: str, flake_machines: dict, discovered_nodes: list):
    """Prunes non-canonical MAC keys belonging to the same physical node as canonical_mac."""
    clean_target = normalize_mac(canonical_mac)
    all_node_macs = []
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
    seen_names = set()
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
            if not macs or any(m in seen_macs for m in macs):
                continue

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

            if resolved_name in seen_names:
                continue
            seen_names.add(resolved_name)
            seen_macs.update(macs)

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
                    raw_ifaces = re.split(r'\n(?=\s*-\s+iface:)', ifaces_m.group(1))
                    for b in raw_ifaces:
                        name_m = re.search(r'iface:\s*([^\s\n]+)', b)
                        mac_m = re.search(r'mac:\s*([^\s\n]+)', b)
                        ips_m = re.search(r'ips:\s*([^\n]*)', b)
                        if name_m:
                            ifname = name_m.group(1).strip()
                            raw_ips_str = ips_m.group(1).strip() if ips_m else ""
                            cleaned_ips = [ip.strip() for ip in raw_ips_str.split(",") if ip.strip()]
                            ip_map[ifname] = cleaned_ips
                            if mac_m and mac_m.group(1).strip():
                                ip_map[normalize_mac(mac_m.group(1).strip())] = cleaned_ips

            # 4. Check active PXE MAC recorded during boot
            target_pxe_mac = None

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
                elif is_public:
                    role = "public"
                else:
                    role = "disabled"

                iface_lines.append(f"      {iface_name} = {{\n        mac = \"{formatted_mac}\";\n        role = \"{role}\";\n      }};")

            # 5. Check NVIDIA GPU presence
            has_nvidia = any(k in payload.lower() for k in ["nvidia", "geforce", "rtx", "cuda", "tesla", "a100", "h100"])
            nvidia_val = "true" if has_nvidia else "false"

            # 5b. Parse TPM 2.0 Presence
            tpm_present = ("tpm:" in payload and "present: true" in payload) or "psp" in payload.lower()

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

            tpm_present_str = "true" if tpm_present else "false"

            if block_devs:
                os_dev = block_devs[0]
                os_path = os_dev["by_id"] if os_dev["by_id"] else f"/dev/{os_dev['name']}"
                disk_lines = [
                    "    osDisk = {",
                    f'      device = "{os_path}";',
                    f"      encrypted = {tpm_present_str};",
                    '      provider = "nodeId";',
                    "    };",
                ]
                if len(block_devs) > 1:
                    disk_lines.append("    # Discovered secondary storage disks (unpartitioned for Kubernetes storage):")
                    for sdev in block_devs[1:]:
                        spath = sdev["by_id"] if sdev["by_id"] else f"/dev/{sdev['name']}"
                        s_gb = sdev["size_bytes"] / (1024**3)
                        model_str = f" ({sdev['model']})" if sdev["model"] else ""
                        disk_lines.append(f"    # - {spath} ({s_gb:.1f} GB{model_str})")
                disk_block = "\n".join(disk_lines)
            else:
                disk_block = """    osDisk = {
      device = "/dev/nvme0n1";
      encrypted = false;
      provider = "nodeId";
    };"""

            ifaces_body = "\n".join(iface_lines)
            entry = f"""  {resolved_name} = {{
    controlPlane = {is_control_plane};
{disk_block}
    nvidia = {nvidia_val};
    tpm = {{
      present = {tpm_present_str};
    }};
    network-interfaces = {{
{ifaces_body}
    }};
  }};"""
            entries.append(entry)
            discovered_nodes_list.append({
                "name": resolved_name,
                "controlPlane": is_control_plane == "true",
                "nvidia": has_nvidia,
                "tpm": {
                    "present": tpm_present,
                },
                "macs": [format_mac(m) for m in macs],
            })
        except Exception as e:
            print(f"[ERROR] Failed to parse {report_path}: {e}", flush=True)

    # Format into Nix attribute set syntax
    nix_body = "{\n" + "\n\n".join(entries) + "\n}\n" if entries else "{\n}\n"
    atomic_save_text(nix_file, nix_body)
    atomic_save_json(nodes_json_file, {"nodes": discovered_nodes_list})
    return nix_body.encode("utf-8")

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
            discovered = get_discovered_nodes()

            target_macs = resolve_target_macs(target, flake_machines, discovered) if target else []
            target_mac = target_macs[0] if target_macs else (format_mac(target) if len(normalize_mac(target)) == 12 else target)

            log_path = None
            if target_mac in wipe_data and wipe_data[target_mac].get("log"):
                log_path = wipe_data[target_mac]["log"]
            elif target_mac:
                clean_mac = target_mac.replace(":", "-")
                for p in sorted(WIPE_LOGS_DIR.glob(f"*{clean_mac}*.log"), reverse=True):
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
            if not self._require_local_auth("Inspection report reading"):
                return
            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            target = query_params.get("node", query_params.get("hostname", [""]))[0]
            if not target:
                subpath = parsed_url.path.replace("/api/reports", "").strip("/")
                if subpath:
                    target = subpath

            if target:
                flake_machines = get_flake_machines()
                discovered = get_discovered_nodes()
                target_macs = resolve_target_macs(target, flake_machines, discovered)
                clean_targets = [m.replace(":", "-") for m in target_macs] if target_macs else []
                clean_targets.append(target.replace(".yaml", "").replace("inspector-report-", "").replace(":", "-"))

                target_file = None
                for filepath in sorted(INSPECTOR_DIR.glob("*.yaml")):
                    if "wipe-log" in filepath.name:
                        continue
                    if any(ct in filepath.name for ct in clean_targets if ct):
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
            if not self._require_local_auth("Hardware discovery"):
                return
            content = generate_machines_nix()
            self._send_text(200, content.decode("utf-8"))
            return

        if self.path == "/api/discovered":
            if not self._require_local_auth("Hardware discovery"):
                return
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

        if self.path in ("/api/installed", "/api/mark-installed"):
            self._handle_post_installed()
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

    def _is_local_client(self) -> bool:
        """Returns True if request originates from localhost/loopback (local CLI or SSH session)."""
        client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else ""
        return client_ip in ("127.0.0.1", "::1", "localhost")

    def _require_local_auth(self, action_name: str) -> bool:
        """Enforces that administrative actions strictly originate from localhost/SSH."""
        if not self._is_local_client():
            client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else "unknown"
            print(f"[SECURITY] Blocked remote {action_name} request from unauthorized IP: {client_ip}", flush=True)
            self._send_json(403, {
                "error": "Forbidden",
                "message": f"{action_name} operations must originate from localhost via an SSH agent-authenticated session."
            })
            return False
        return True

    def _handle_purge(self):
        """Purges all inspector reports, wipe states, logs, and generated Talos state files (Localhost / SSH only)."""
        if not self._require_local_auth("Cluster purge"):
            return

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
        if not self._require_local_auth("Cluster status inspection"):
            return

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
            "discovered_nodes": get_discovered_nodes(),
            "wipe_data": wipe_data
        })

    def _handle_post_installed(self):
        """Allows setting or toggling node installed state via POST /api/installed (Localhost / SSH-authenticated only)."""
        if not self._require_local_auth("Installed state management"):
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else "{}"
        try:
            req = json.loads(body)
        except Exception:
            req = {}

        target = req.get("target", "all")
        installed = bool(req.get("installed", True))
        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()
        discovered_nodes = get_discovered_nodes()
        iso_now = datetime.now(timezone.utc).isoformat()

        target_macs = resolve_target_macs(target, flake_machines, discovered_nodes)
        if not target_macs:
            self._send_json(400, {
                "error": "Bad Request",
                "message": f"Target '{target}' is not a declared node in machines.nix or a discovered bare-metal node."
            })
            return

        for mac in target_macs:
            if mac not in wipe_data:
                wipe_data[mac] = {
                    "requested": False,
                    "status": "NONE",
                    "timestamp": None,
                    "log": None,
                    "installed": False,
                    "installed_at": None,
                }
            wipe_data[mac]["installed"] = installed
            wipe_data[mac]["installed_at"] = iso_now if installed else None
            if installed:
                wipe_data[mac]["requested"] = False

        save_wipe_data(wipe_data)
        self._send_json(200, {"status": "success", "target": target, "resolved_macs": target_macs, "installed": installed})

    def _handle_post_wipe(self):
        """Allows toggling wipe requests via POST /api/wipe (Localhost / SSH-authenticated only)."""
        if not self._require_local_auth("Destructive storage wipe"):
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
        discovered_nodes = get_discovered_nodes()
        iso_now = datetime.now(timezone.utc).isoformat()

        target_macs = resolve_target_macs(target, flake_machines, discovered_nodes)
        if not target_macs:
            self._send_json(400, {
                "error": "Bad Request",
                "message": f"Target '{target}' is not a declared node in machines.nix or a discovered bare-metal node."
            })
            return

        for mac in target_macs:
            if mac not in wipe_data:
                wipe_data[mac] = {
                    "requested": False,
                    "status": "NONE",
                    "timestamp": None,
                    "log": None,
                    "installed": False,
                    "installed_at": None,
                }
            if requested is not None:
                wipe_data[mac]["requested"] = requested
                if requested:
                    wipe_data[mac]["installed"] = False
            if explicit_status:
                wipe_data[mac]["status"] = explicit_status
            else:
                wipe_data[mac]["status"] = "PENDING" if (requested if requested is not None else False) else "NONE"
            wipe_data[mac]["timestamp"] = iso_now

        save_wipe_data(wipe_data)
        self._send_json(200, {
            "status": "success",
            "target": target,
            "resolved_macs": target_macs,
            "wipe_requested": requested,
            "node_status": explicit_status
        })

    def _handle_boot_ipxe(self):
        parsed_url = urlparse(self.path)
        query_params = parse_qs(parsed_url.query)
        mac = query_params.get("mac", [""])[0].lower()
        clean_req_mac = normalize_mac(mac)
        formatted_req_mac = format_mac(clean_req_mac)

        wipe_data = get_wipe_data()
        flake_machines = get_flake_machines()
        iso_now = datetime.now(timezone.utc).isoformat()

        # Check if MAC is declared in machines.nix
        declared_name = None
        is_control_plane = False
        is_nvidia = False
        if flake_machines:
            for fname, fspec in flake_machines.items():
                if isinstance(fspec, dict):
                    fmacs = [normalize_mac(m) for m in fspec.get("macs", [])]
                    if clean_req_mac in fmacs:
                        declared_name = fname
                        is_control_plane = bool(fspec.get("controlPlane"))
                        is_nvidia = bool(fspec.get("nvidia"))
                        break

        is_declared = declared_name is not None
        name = declared_name or f"node-{clean_req_mac[-6:] if clean_req_mac else 'unknown'}"
        vmlinuz_path = Path("/var/lib/tftpboot") / name / "vmlinuz"

        discovered_nodes = get_discovered_nodes()
        target_macs = resolve_target_macs(clean_req_mac, flake_machines, discovered_nodes)
        canonical_mac = target_macs[0] if target_macs else formatted_req_mac

        prune_secondary_mac_keys(wipe_data, canonical_mac, flake_machines, discovered_nodes)

        # Check wipe request for this MAC
        wentry = wipe_data.get(canonical_mac, {})
        should_wipe = wentry.get("requested", False) or wentry.get("status") == "IN_PROGRESS"

        if should_wipe:
            boot_target = "Inspector (Wipe)"
        elif not is_declared or not vmlinuz_path.exists():
            boot_target = "Inspector (Discover)"
        else:
            boot_target = "Talos"

        dns_ip_env = os.environ.get("DNS_IP", "127.0.0.1")
        host_header = self.headers.get("Host", dns_ip_env)
        server_ip = host_header.split(":")[0] if host_header else dns_ip_env
        if server_ip in ("127.0.0.1", "localhost") and dns_ip_env not in ("127.0.0.1", "localhost"):
            server_ip = dns_ip_env

        client_ip = self.client_address[0] if hasattr(self, 'client_address') and self.client_address else None

        if canonical_mac not in wipe_data:
            wipe_data[canonical_mac] = {
                "requested": should_wipe,
                "status": "IN_PROGRESS" if should_wipe else "NONE",
                "timestamp": iso_now,
                "log": None,
                "pxe_ip": client_ip,
                "installed": False,
                "installed_at": None,
            }
        else:
            if client_ip:
                wipe_data[canonical_mac]["pxe_ip"] = client_ip
            if should_wipe:
                wipe_data[canonical_mac]["status"] = "IN_PROGRESS"
                wipe_data[canonical_mac]["timestamp"] = iso_now
                wipe_data[canonical_mac]["installed"] = False
        save_wipe_data(wipe_data)

        if boot_target == "Inspector (Wipe)":
            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  STORAGE WIPE | SANITIZING LOCAL STORAGE ({name})
echo ========================================================================
echo   MAC Address : {formatted_req_mac}
echo   Target Host : {name}
echo   Coordinator : {server_ip}:{PORT}
echo   Action      : BOOTING INTO INSPECTOR RAMDISK TO WIPE LOCAL DISKS
echo ========================================================================
echo
sleep 3
set cmdline coordinator.server=http://{server_ip}:{PORT} inspector.server=http://{server_ip}:{PORT} inspector.wipe=1
chain http://{server_ip}/default/netboot.ipxe
"""
        elif boot_target == "Inspector (Discover)":
            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  AI VILLAGE HARDWARE INSPECTOR | STATELESS DISCOVERY ({name})
echo ========================================================================
echo   MAC Address : {formatted_req_mac}
echo   Status      : UNREGISTERED / HARDWARE DISCOVERY
echo   Coordinator : {server_ip}:{PORT}
echo   Action      : BOOTING INTO INSPECTOR RAMDISK TO REPORT HARDWARE
echo ========================================================================
echo
sleep 2
set cmdline coordinator.server=http://{server_ip}:{PORT} inspector.server=http://{server_ip}:{PORT}
chain http://{server_ip}/default/netboot.ipxe
"""
        else: # Talos
            node_role = "CONTROL PLANE" if is_control_plane else "WORKER"
            role_desc = f"{node_role} (nvidia = true)" if is_nvidia else node_role
            ramdisk_desc = "TALOS OS + NVIDIA GPU DRIVERS (506 MB)" if is_nvidia else "TALOS OS KERNEL & INITRAMFS (103 MB)"
            config_url = f"http://{server_ip}:{PORT}/configs/{name}.yaml"

            ipxe_script = f"""#!ipxe
echo
echo ========================================================================
echo  TALOS OS | BARE-METAL KUBERNETES INSTALL ({name})
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
        is_age_req = conf_name.endswith(".age")
        target_conf = conf_name[:-4] if is_age_req else conf_name
        node_key = target_conf.replace(".yaml", "")

        conf_path = CONFIGS_DIR / target_conf
        content = None

        # Check if requested config is a shared patch/manifest (e.g. cilium.yaml, cni.yaml)
        gen_patches = CONFIGS_DIR / "generate-patches" / "bin" / "generate-patches"
        if not (conf_path.exists() and conf_path.is_dir() and (conf_path / "bin" / "generate-config").exists()):
            if gen_patches.exists():
                try:
                    TALOS_DIR.mkdir(parents=True, exist_ok=True)
                    subprocess.run([str(gen_patches), str(TALOS_DIR)], capture_output=True, text=True, cwd=str(TALOS_DIR))
                    for candidate in [TALOS_DIR / target_conf, TALOS_DIR / "addons" / target_conf, TALOS_DIR / "base-patches" / target_conf]:
                        if candidate.exists() and candidate.is_file():
                            content = candidate.read_bytes()
                            break
                except Exception:
                    pass

            if content is not None:
                self.send_response(200)
                self.send_header("Content-Type", "application/yaml; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
                return

        # Declarative Gating: If the node is not declared in flake machines, reject with 404
        flake_machines = get_flake_machines()
        if not flake_machines or node_key not in flake_machines:
            self._send_json(404, {"error": "Not Found", "message": f"Machine '{node_key}' is not declared in cluster machines."})
            return

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
                print(f"[ERROR] generate-config failed for {target_conf} ({res.returncode}):\n{res.stderr}", flush=True)
                err_msg = f"# ERROR: generate-config failed for {target_conf}\n# Exit code: {res.returncode}\n\n{res.stderr}".encode("utf-8")
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

            yaml_file = TALOS_DIR / target_conf
            if not yaml_file.exists():
                for alt in [TALOS_DIR / "controlplane.yaml", TALOS_DIR / "worker.yaml"]:
                    if alt.exists():
                        yaml_file = alt
                        break

            if yaml_file.exists():
                content = yaml_file.read_bytes()
            else:
                print(f"[ERROR] Output config {yaml_file} not found: {res.stderr}", flush=True)

        if content is not None:
            self.send_response(200)
            self.send_header("Content-Type", "text/yaml")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        else:
            self._send_json(404, {"error": "Not Found", "message": f"Config for '{target_conf}' could not be generated or found."})

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
        discovered_nodes = get_discovered_nodes()

        target_macs = []
        for m in clean_macs:
            resolved = resolve_target_macs(m, flake_machines, discovered_nodes)
            if resolved:
                target_macs = resolved
                break

        if not target_macs and hostname:
            target_macs = resolve_target_macs(hostname, flake_machines, discovered_nodes)

        target_mac = target_macs[0] if target_macs else (format_mac(clean_macs[0]) if clean_macs else hostname)

        prune_secondary_mac_keys(wipe_data, target_mac, flake_machines, discovered_nodes)

        log_filename = f"wipe-{target_mac.replace(':', '-')}-{ts_str}.log"
        log_path = WIPE_LOGS_DIR / log_filename
        atomic_save_text(log_path, payload)

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
        print(f"[WIPE] Saved wipe log for {target_mac} ({hostname}) to {log_path}", flush=True)
        self._send_json(200, {"status": "SUCCESS", "log_file": str(log_path)})

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

        # Determine target_mac from reported primary_mac, declared flake machine MACs, or first clean MAC
        pmac_match = re.search(r'primary_mac:\s*["\']?([0-9a-fA-F:]{17})["\']?', payload)
        reported_pmac = normalize_mac(pmac_match.group(1)) if pmac_match else None

        target_mac = None
        if reported_pmac:
            target_mac = format_mac(reported_pmac)
        elif clean_macs:
            target_mac = format_mac(clean_macs[0])
        else:
            target_mac = hostname

        filename = f"inspector-report-{target_mac.replace(':', '-')}.yaml"
        filepath = INSPECTOR_DIR / filename
        atomic_save_text(filepath, payload)

        # Remove any older reports for the same machine to prevent duplicates
        clean_mac_set = set(clean_macs)
        for old_path in INSPECTOR_DIR.glob("*.yaml"):
            if "wipe-log" in old_path.name or old_path.name == filename:
                continue
            for cm in clean_mac_set:
                if cm.replace(":", "-") in old_path.name:
                    try:
                        old_path.unlink(missing_ok=True)
                    except Exception:
                        pass

        try:
            generate_machines_nix()
        except Exception as e:
            print(f"[WARN] Failed to auto-generate machines.nix: {e}", flush=True)

        wipe_data = get_wipe_data()
        should_wipe = False
        if target_mac in wipe_data:
            wentry = wipe_data[target_mac]
            if wentry.get("requested", False) or wentry.get("status") == "IN_PROGRESS":
                should_wipe = True
                wentry["status"] = "IN_PROGRESS"
                save_wipe_data(wipe_data)

        print(f"[RECV] Saved report for {target_mac} (wipe={should_wipe})", flush=True)

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

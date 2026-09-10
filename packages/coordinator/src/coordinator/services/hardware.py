import os
import re
from typing import Any, Dict, List, Tuple
import yaml

from coordinator.config import settings
from coordinator.services.state_store import (
    normalize_mac,
    format_mac,
    atomic_save_text,
    atomic_save_json,
    get_flake_machines,
    get_wipe_data,
)


def get_subnet_prefix(cidr: str) -> str:
    """Extracts the first 3 octets prefix from a CIDR subnet string."""
    if cidr and "/" in cidr:
        return ".".join(cidr.split("/")[0].split(".")[:3]) + "."
    return ""


def compile_hardware_reports() -> Tuple[str, List[Dict[str, Any]]]:
    """
    Dynamically compiles all saved YAML hardware reports in INSPECTOR_DIR
    into machines.nix and discovered-nodes.json.
    """
    settings.inspector_dir.mkdir(parents=True, exist_ok=True)
    nix_file = settings.inspector_dir / "machines.nix"
    nodes_json_file = settings.inspector_dir / "discovered-nodes.json"

    flake_machines = get_flake_machines()
    _wipe_data = get_wipe_data()

    entries: List[str] = []
    discovered_nodes_list: List[Dict[str, Any]] = []
    seen_names = set()
    seen_macs = set()

    for report_path in sorted(settings.inspector_dir.glob("*.yaml")):
        if "wipe-log" in report_path.name:
            continue
        try:
            payload = report_path.read_text(encoding="utf-8")

            # 1. Parse Network Devices
            devices: List[Tuple[str, str]] = []
            net_match = re.search(r"network_devices:\s*\n([\s\S]*?)(?=\n\w+:|$)", payload)
            if net_match:
                devices = re.findall(
                    r"name:\s*([^\s\n]+)[\s\S]*?mac_address:\s*([0-9a-fA-F:]{17})",
                    net_match.group(1),
                )

            if not devices:
                macs = re.findall(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", payload)
                devices = [(f"enp{idx+3}s0", m) for idx, m in enumerate(macs)]

            macs_norm = [normalize_mac(d[1]) for d in devices]
            if not macs_norm or any(m in seen_macs for m in macs_norm):
                continue

            # 2. Match host against Flake-declared machines
            resolved_name = None
            is_control_plane = "false"

            for mac in macs_norm:
                for name, spec in flake_machines.items():
                    if not isinstance(spec, dict):
                        continue
                    net_ifaces = spec.get("network-interfaces", {})
                    matched_macs = [
                        normalize_mac(attrs.get("mac", ""))
                        for attrs in net_ifaces.values()
                        if isinstance(attrs, dict)
                    ]
                    if not matched_macs:
                        matched_macs = [
                            normalize_mac(m)
                            for m in spec.get("macs", [])
                            if isinstance(m, str)
                        ]
                    if mac in matched_macs:
                        resolved_name = name
                        if spec.get("controlPlane", False):
                            is_control_plane = "true"
                        break
                if resolved_name:
                    break

            if not resolved_name:
                mac_suffix = macs_norm[0][-6:] if len(macs_norm[0]) >= 6 else "unknown"
                resolved_name = f"node-{mac_suffix}"

            if resolved_name in seen_names:
                continue
            seen_names.add(resolved_name)
            seen_macs.update(macs_norm)

            # 3. Parse active IPs and primary interface reported by Inspector
            ip_map: Dict[str, List[str]] = {}
            primary_iface_reported = ""
            primary_mac_reported = ""

            net_header = re.search(r"network:\s*\n([\s\S]*?)(?=\n\w+:|$)", payload)
            if net_header:
                pif_m = re.search(r"primary_iface:\s*([^\s\n]+)", net_header.group(1))
                pmac_m = re.search(r"primary_mac:\s*([^\s\n]+)", net_header.group(1))
                if pif_m:
                    primary_iface_reported = pif_m.group(1).strip()
                if pmac_m:
                    primary_mac_reported = normalize_mac(pmac_m.group(1).strip())

                ifaces_m = re.search(
                    r"interfaces:\s*\n([\s\S]*?)(?=\n\w+:|$)", net_header.group(1)
                )
                if ifaces_m:
                    raw_ifaces = re.split(r"\n(?=\s*-\s+iface:)", ifaces_m.group(1))
                    for b in raw_ifaces:
                        name_m = re.search(r"iface:\s*([^\s\n]+)", b)
                        mac_m = re.search(r"mac:\s*([^\s\n]+)", b)
                        ips_m = re.search(r"ips:\s*([^\n]*)", b)
                        if name_m:
                            ifname = name_m.group(1).strip()
                            raw_ips_str = ips_m.group(1).strip() if ips_m else ""
                            cleaned_ips = [
                                ip.strip() for ip in raw_ips_str.split(",") if ip.strip()
                            ]
                            ip_map[ifname] = cleaned_ips
                            if mac_m and mac_m.group(1).strip():
                                ip_map[normalize_mac(mac_m.group(1).strip())] = cleaned_ips

            # 4. Check active PXE MAC recorded during boot & subnet configuration
            private_prefix = get_subnet_prefix(settings.PRIVATE_SUBNET)
            public_prefix = get_subnet_prefix(settings.PUBLIC_SUBNET)

            # Detect private and public interfaces based on IP addresses
            private_detected_ifaces: List[str] = []
            if private_prefix:
                for iface_name, mac in devices:
                    clean_mac = normalize_mac(mac)
                    iface_ips = ip_map.get(iface_name, []) + ip_map.get(clean_mac, [])
                    if any(ip.startswith(private_prefix) for ip in iface_ips):
                        private_detected_ifaces.append(iface_name)

            enable_bonding = len(private_detected_ifaces) > 1

            # Determine the single canonical primary interface if bonding is not enabled
            chosen_primary_iface = None
            if len(private_detected_ifaces) == 1:
                chosen_primary_iface = private_detected_ifaces[0]
            elif not private_detected_ifaces:
                if primary_mac_reported or primary_iface_reported:
                    for iface_name, mac in devices:
                        clean_mac = normalize_mac(mac)
                        if (primary_mac_reported and clean_mac == primary_mac_reported) or (
                            primary_iface_reported and iface_name == primary_iface_reported
                        ):
                            chosen_primary_iface = iface_name
                            break
                if not chosen_primary_iface and devices:
                    chosen_primary_iface = devices[0][0]

            iface_lines: List[str] = []
            for idx, (iface_name, mac) in enumerate(devices):
                clean_mac = normalize_mac(mac)
                formatted_mac_str = format_mac(clean_mac)
                iface_ips = ip_map.get(iface_name, []) + ip_map.get(clean_mac, [])
                is_public = (
                    any(ip.startswith(public_prefix) for ip in iface_ips)
                    if public_prefix
                    else False
                )

                if enable_bonding:
                    if iface_name in private_detected_ifaces:
                        role = "private"
                    elif is_control_plane == "true":
                        role = "disabled"
                    elif is_public:
                        role = "public"
                    else:
                        role = "disabled"
                else:
                    if iface_name == chosen_primary_iface:
                        role = "private"
                    elif is_control_plane == "true":
                        role = "disabled"
                    elif is_public:
                        role = "public"
                    else:
                        role = "disabled"

                iface_lines.append(
                    f"      {iface_name} = {{\n        mac = \"{formatted_mac_str}\";\n        role = \"{role}\";\n      }};"
                )

            # 5. Check NVIDIA GPU presence
            has_nvidia = any(
                k in payload.lower()
                for k in ["nvidia", "geforce", "rtx", "cuda", "tesla", "a100", "h100"]
            )
            nvidia_val = "true" if has_nvidia else "false"

            # 5b. Parse TPM 2.0 Presence
            tpm_present = ("tpm:" in payload and "present: true" in payload) or "psp" in payload.lower()

            # 6. Parse Block Devices
            block_devs: List[Dict[str, Any]] = []
            blk_match = re.search(r"block_devices:\s*\n([\s\S]*?)(?=\n\w+:|$)", payload)
            if blk_match:
                raw_items = re.split(r"\n(?=-\s+name:)", "\n" + blk_match.group(1))
                for item in raw_items:
                    name_m = re.search(r"name:\s*([^\s\n]+)", item)
                    size_m = re.search(r"size_bytes:\s*([0-9]+)", item)
                    by_id_m = re.search(r"by_id:\s*([^\s\n]+)", item)
                    model_m = re.search(r"model:\s*(?:[\"']?([^\"'\n]+)[\"']?)", item)
                    tran_m = re.search(r"transport:\s*([^\s\n]+)", item)
                    if name_m and size_m:
                        block_devs.append({
                            "name": name_m.group(1).strip(),
                            "size_bytes": int(size_m.group(1)),
                            "by_id": (
                                by_id_m.group(1).strip()
                                if by_id_m and by_id_m.group(1) != "null"
                                else ""
                            ),
                            "model": (
                                model_m.group(1).strip()
                                if model_m and model_m.group(1) != "null"
                                else ""
                            ),
                            "transport": (
                                tran_m.group(1).strip()
                                if tran_m and tran_m.group(1) != "null"
                                else ""
                            ),
                        })

            # Sort: smaller drives first, NVMe preferred over SATA, alphabetical tie-breaker
            block_devs.sort(
                key=lambda d: (
                    d["size_bytes"],
                    0 if d["transport"] == "nvme" else 1,
                    d["name"],
                )
            )

            tpm_present_str = "true" if tpm_present else "false"

            if block_devs:
                os_dev = block_devs[0]
                os_path = os_dev["by_id"] if os_dev["by_id"] else f"/dev/{os_dev['name']}"
                disk_lines = [
                    "    disks = {",
                    "      os = {",
                    f'        device = "{os_path}";',
                    f"        encrypted = {tpm_present_str};",
                    '        provider = "nodeId";',
                    "      };",
                ]
                if len(block_devs) > 1:
                    models_dev = block_devs[1]
                    models_path = (
                        models_dev["by_id"]
                        if models_dev["by_id"]
                        else f"/dev/{models_dev['name']}"
                    )
                    disk_lines.extend([
                        "      models = {",
                        f'        device = "{models_path}";',
                        "      };",
                    ])
                disk_lines.append("    };")
                if len(block_devs) > 2:
                    disk_lines.append(
                        "    # Additional discovered storage disks (unpartitioned for Kubernetes storage):"
                    )
                    for sdev in block_devs[2:]:
                        spath = (
                            sdev["by_id"] if sdev["by_id"] else f"/dev/{sdev['name']}"
                        )
                        s_gb = sdev["size_bytes"] / (1024**3)
                        model_str = f" ({sdev['model']})" if sdev["model"] else ""
                        disk_lines.append(f"    # - {spath} ({s_gb:.1f} GB{model_str})")
                disk_block = "\n".join(disk_lines)
            else:
                disk_block = """    disks = {
      os = {
        device = "/dev/nvme0n1";
        encrypted = false;
        provider = "nodeId";
      };
    };"""

            ifaces_body = "\n".join(iface_lines)
            bonding_block = """    bonding = {
      enable = true;
      mode = "802.3ad";
    };
""" if enable_bonding else ""

            entry = f"""  {resolved_name} = {{
    controlPlane = {is_control_plane};
{disk_block}
    nvidia = {nvidia_val};
    tpm = {{
      present = {tpm_present_str};
    }};
{bonding_block}    network-interfaces = {{
{ifaces_body}
    }};
  }};"""
            entries.append(entry)
            node_entry = {
                "name": resolved_name,
                "controlPlane": is_control_plane == "true",
                "nvidia": has_nvidia,
                "tpm": {
                    "present": tpm_present,
                },
                "macs": [format_mac(m) for m in macs_norm],
            }
            if enable_bonding:
                node_entry["bonding"] = {
                    "enable": True,
                    "mode": "802.3ad",
                }
            discovered_nodes_list.append(node_entry)
        except Exception as e:
            print(f"[ERROR] Failed to parse {report_path}: {e}", flush=True)

    # Format into Nix attribute set syntax
    nix_body = "{\n" + "\n\n".join(entries) + "\n}\n" if entries else "{\n}\n"
    atomic_save_text(nix_file, nix_body)
    atomic_save_json(nodes_json_file, {"nodes": discovered_nodes_list})
    return nix_body, discovered_nodes_list


def get_discovered_nodes_data() -> List[Dict[str, Any]]:
    """Reads discovered-nodes.json or compiles from hardware reports if missing."""
    nodes_json_file = settings.inspector_dir / "discovered-nodes.json"
    if nodes_json_file.exists():
        try:
            raw = yaml.safe_load(nodes_json_file.read_text(encoding="utf-8"))
            if isinstance(raw, dict) and "nodes" in raw:
                return raw["nodes"]
        except Exception as e:
            print(f"[WARN] Failed to load {nodes_json_file}: {e}", flush=True)
    _, nodes = compile_hardware_reports()
    return nodes


generate_machines_nix = compile_hardware_reports


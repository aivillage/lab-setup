from typing import Optional


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


def is_valid_mac(mac: Optional[str]) -> bool:
    """Validates whether string represents a valid 6-byte IEEE 802 MAC address."""
    clean = normalize_mac(mac)
    return len(clean) == 12 and all(c in "0123456789abcdef" for c in clean)

import socket
from cluster_cli.utils.mac import normalize_mac, is_valid_mac


def send_wol_packet(
    mac_str: str, broadcast_ip: str = "255.255.255.255", port: int = 9
) -> None:
    """Constructs and broadcasts an IEEE 802 Wake-on-LAN magic packet."""
    clean_mac = normalize_mac(mac_str)
    if not is_valid_mac(clean_mac):
        raise ValueError(f"Invalid MAC address format for Wake-on-LAN: {mac_str}")

    mac_bytes = bytes.fromhex(clean_mac)
    magic_packet = b"\xff" * 6 + mac_bytes * 16

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(magic_packet, (broadcast_ip, port))

#!/usr/bin/env bash

_COORD=$(grep -oP '(?:inspector|coordinator)\.server=\K\S+' /proc/cmdline 2>/dev/null | head -n1 || true)
_COORD_HOST=$(echo "$_COORD" | sed -E 's|^https?://||; s|:[0-9]+.*||; s|/.*||')
_DEF_DEV=""
_IP=""
if [ -n "$_COORD_HOST" ]; then
  _ROUTE=$(ip route get "$_COORD_HOST" 2>/dev/null | head -n1 || true)
  _DEF_DEV=$(echo "$_ROUTE" | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
  _IP=$(echo "$_ROUTE" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
fi
if [ -z "$_DEF_DEV" ]; then
  _DEF_DEV=$(ip route show default 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
fi
if [ -z "$_DEF_DEV" ]; then
  _DEF_DEV=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | head -n1)
fi
if [ -z "$_DEF_DEV" ]; then
  for _cand in /sys/class/net/*; do
    if [ -d "$_cand" ]; then
      _cand_name=$(basename "$_cand")
      if [[ "$_cand_name" =~ ^(lo|dummy.*|sit.*|tun.*)$ ]]; then
        continue
      fi
      _DEF_DEV="$_cand_name"
      break
    fi
  done
fi
if [ -z "$_IP" ] && [ -n "$_DEF_DEV" ]; then
  for _ in $(seq 1 10); do
    _IP=$(ip -4 addr show dev "$_DEF_DEV" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    [ -n "$_IP" ] && break
    sleep 0.2
  done
fi
if [ -n "$_IP" ]; then
  _STATUS="Online"
  _SSH_HINT="ssh admin@$_IP"
else
  _STATUS="DHCP Pending"
  _IP="Waiting for DHCP..."
  _SSH_HINT="ssh admin@<ip> (DHCP pending)"
fi
_MAC="unknown"
if [ -n "$_DEF_DEV" ] && [ -f "/sys/class/net/$_DEF_DEV/address" ]; then
  _MAC=$(cat "/sys/class/net/$_DEF_DEV/address" 2>/dev/null || echo 'unknown')
fi
_TPM="Not detected"
if [ -e /dev/tpmrm0 ]; then
  _TPM="Present (/dev/tpmrm0)"
fi
[ -z "$_COORD" ] && _COORD="DHCP/DNS Discovery"

_DISKS=$(lsblk -d -n -o NAME,SIZE,MODEL 2>/dev/null | grep -Ev '^(loop|ram|zram|sr)' | sed 's/^/    /' || true)
[ -z "$_DISKS" ] && _DISKS="    (none detected)"

echo "========================================================================"
echo "   AI VILLAGE HARDWARE INSPECTOR - EMERGENCY DIAGNOSTICS"
echo "========================================================================"
echo "EMERGENCY FALLBACK: Inspector service encountered an error."
echo "Network and SSH remain ACTIVE for manual triage."
echo ""
echo "[ Network & Access ]"
echo "  Status        : $_STATUS"
echo "  SSH Login     : $_SSH_HINT"
echo "  Interface     : ${_DEF_DEV:-unknown} ($_MAC)"
echo "  Coordinator   : $_COORD"
echo ""
echo "[ Hardware Inventory ]"
echo "  TPM 2.0       : $_TPM"
echo "  Disks         :"
echo "$_DISKS"
echo ""
echo "[ Triage Commands ]"
echo "  journalctl -u inspector-report -e -> View background upload logs"
echo "  inspector inspect                 -> Re-run hardware inspection report"
echo "  inspector wipe --confirm          -> Wipe local disks and power off"
echo "========================================================================"

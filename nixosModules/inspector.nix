{
  config,
  lib,
  pkgs,
  ...
}:
let
  configuredHostName = config.networking.hostName;
in
{
  config = {
    boot.kernelParams = [ "console=tty0" ];
    boot.zfs.forceImportRoot = false;

    # Auto-login root on console
    services.getty.autologinUser = lib.mkDefault "root";

    # Enable SSH for manual debugging/inspection
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "yes";
        PasswordAuthentication = true;
      };
    };

    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMsmsLubwu6s0wkeKTsM2EIuJRKFsg2nZdRCVtQHk9LT thurs"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE/PhAuMI529/ah9/nY27UHo0G/UMCTsZcGhmYk+O3Lv admin@aivillage.org"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOugqVQLYj89EwYEGthEt0C7OlZh6xRelBdb3LvFDzJb sven@nbhd.ai"
    ];

    environment.systemPackages = with pkgs; [
      conntrack-tools
      curl
      dmidecode
      ethtool
      gptfdisk
      htop
      inspector
      jq
      lshw
      parted
      pciutils
      smartmontools
      tcpdump
      usbutils
      util-linux
    ];

    programs.nix-ld.enable = true;

    systemd.services.inspector-report = {
      description = "Run Hardware Inspector and POST report to CNC server";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      path = with pkgs; [
        coreutils
        curl
        dmidecode
        gptfdisk
        hostname
        iproute2
        jq
        parted
        pciutils
        systemd
        util-linux
      ];

      script = ''
        set -u

        REPORT_FILE="/tmp/inspector-report.yaml"
        LOG_FILE="/var/log/inspector-report.yaml"

        # Discover default/primary network interface and node IP
        PRIMARY_IFACE=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -n1 || true)
        if [ -z "$PRIMARY_IFACE" ]; then
          for dev in /sys/class/net/*; do
            if [ -d "$dev" ]; then
              devname=$(basename "$dev")
              if [ "$devname" != "lo" ] && [ -f "$dev/address" ]; then
                PRIMARY_IFACE="$devname"
                break
              fi
            fi
          done
        fi

        MY_IP=""
        if [ -n "$PRIMARY_IFACE" ]; then
          MY_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)
        fi

        # Helper to check if a candidate hostname is valid and non-generic
        is_valid_hostname() {
          local name="$1"
          if [ -z "$name" ]; then return 1; fi
          case "$name" in
            localhost*|nixos*|inspector*|"(none)"|"") return 1 ;;
            *) return 0 ;;
          esac
        }

        NODE_HOSTNAME=""

        # 1. Determine system hostname (e.g. set via DHCP or kernel arg)
        SYS_HOST=$(hostname 2>/dev/null || echo "")
        if is_valid_hostname "$SYS_HOST"; then
          NODE_HOSTNAME="$SYS_HOST"
        fi

        # 2. Reverse DNS lookup on active interface IP
        if ! is_valid_hostname "$NODE_HOSTNAME" && [ -n "$MY_IP" ]; then
          PTR_NAME=$(getent hosts "$MY_IP" 2>/dev/null | awk '{print $2}' | head -n1 || true)
          if is_valid_hostname "$PTR_NAME"; then
            NODE_HOSTNAME="$PTR_NAME"
          fi
        fi

        # 3. Fallback to Deterministic Lowest Physical Interface MAC Address (Port 0)
        if ! is_valid_hostname "$NODE_HOSTNAME"; then
          MAC_ADDR=$(for dev in /sys/class/net/*; do
            if [ -d "$dev" ] && [ "$(basename "$dev")" != "lo" ] && [ -f "$dev/address" ] && [ -d "$dev/device" ]; then
              cand=$(cat "$dev/address" 2>/dev/null | tr ':' '-' | tr -d ' \t\n\r' || true)
              if [ -n "$cand" ] && [ "$cand" != "00-00-00-00-00-00" ]; then
                echo "$cand"
              fi
            fi
          done | sort | head -n1 || true)

          if [ -n "$MAC_ADDR" ] && [ "$MAC_ADDR" != "00-00-00-00-00-00" ]; then
            NODE_HOSTNAME="$MAC_ADDR"
          fi
        fi

        # 4. Fallback to DMI System Serial Number
        if ! is_valid_hostname "$NODE_HOSTNAME"; then
          DMI_SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | tr -d ' \t\n\r' || true)
          if [ -n "$DMI_SERIAL" ] && [ "$DMI_SERIAL" != "NotSpecified" ] && [ "$DMI_SERIAL" != "To-be-filled-by-O.E.M." ]; then
            NODE_HOSTNAME="$DMI_SERIAL"
          fi
        fi

        # 5. Final fallback to configuredHostName option
        if ! is_valid_hostname "$NODE_HOSTNAME"; then
          NODE_HOSTNAME="${configuredHostName}"
        fi

        if ! is_valid_hostname "$NODE_HOSTNAME"; then
          NODE_HOSTNAME="unknown-node"
        fi

        echo "==> Running Hardware Inspector for host: $NODE_HOSTNAME..."
        ${lib.getExe pkgs.inspector} inspect > "$REPORT_FILE"
        cp "$REPORT_FILE" "$LOG_FILE"

        # Discover CNC Server Target (cmdline -> DHCP Gateway)
        CMDLINE_SERVER=$(cat /proc/cmdline | grep -oP 'inspector.server=\K\S+' || true)
        GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

        if [ -n "$CMDLINE_SERVER" ]; then
          CNC_SERVER="$CMDLINE_SERVER"
        elif [ -n "$GATEWAY_IP" ]; then
          CNC_SERVER="$GATEWAY_IP:8080"
        else
          echo "[ERROR] Could not discover CNC Server target (no cmdline inspector.server and no default gateway route)."
          exit 1
        fi

        # Normalize protocol prefix
        if [[ "$CNC_SERVER" != http* ]]; then
          CNC_SERVER="http://$CNC_SERVER"
        fi

        echo "==> Attempting HTTP POST report to $CNC_SERVER/api/reports?hostname=$NODE_HOSTNAME"

        HTTP_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -X POST \
          -H "Content-Type: application/x-yaml" \
          --data-binary @"$REPORT_FILE" \
          "$CNC_SERVER/api/reports?hostname=$NODE_HOSTNAME" || true)

        if [ -n "$HTTP_RESPONSE" ] && echo "$HTTP_RESPONSE" | jq -e . >/dev/null 2>&1; then
          echo "==> HTTP POST report uploaded successfully!"
          echo "==> Server response: $HTTP_RESPONSE"

          WIPE_REQUESTED=$(echo "$HTTP_RESPONSE" | jq -r '.wipe // false')
          if [ "$WIPE_REQUESTED" = "true" ]; then
            echo "==> WARNING: Server requested DISK WIPE!"
            WIPE_LOG="/var/log/wipe-$NODE_HOSTNAME-$(date +%s).log"
            ${lib.getExe pkgs.inspector} wipe --confirm > "$WIPE_LOG" 2>&1 || true

            # Upload wipe log back to CNC server
            curl -s --connect-timeout 10 -X POST \
              -H "Content-Type: text/plain" \
              --data-binary @"$WIPE_LOG" \
              "$CNC_SERVER/api/reports?hostname=$NODE_HOSTNAME-wipe-log" || true
          fi

          echo "==> Flushing buffers and powering off..."
          sync
          poweroff
        else
          echo "========================================================================="
          echo "[ERROR] HTTP POST report upload failed or CNC server unreachable at $CNC_SERVER"
          echo "[INFO] Report saved locally at: $LOG_FILE"
          echo "[INFO] SSH is ACTIVE. Node will remain powered on for manual inspection."
          echo "========================================================================="
        fi
      '';

      serviceConfig = {
        Type = "oneshot";
      };
    };

    system.stateVersion = "25.11";
  };
}

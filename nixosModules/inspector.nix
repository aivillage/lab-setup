{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.inspector = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized for debug console in Inspector RAMDisk";
    };
  };

  config = {
    networking.hostName = lib.mkDefault "inspector";

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

    users.users.root.openssh.authorizedKeys.keys = config.inspector.authorizedKeys;

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
      description = "Run Hardware Inspector and POST report to Coordinator server";

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        OnFailure = [ "inspector-emergency.service" ];
      };

      path = with pkgs; [
        coreutils
        curl
        dmidecode
        gawk
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

        echo "==> Waiting for network connectivity and default route..."
        PRIMARY_IFACE=""
        MY_IP=""
        for i in $(seq 1 30); do
          PRIMARY_IFACE=$(ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -n1 || true)
          if [ -n "$PRIMARY_IFACE" ]; then
            MY_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)
            if [ -n "$MY_IP" ]; then
              echo "==> Acquired IP $MY_IP on interface $PRIMARY_IFACE"
              break
            fi
          fi
          sleep 1
        done

        if [ -z "$PRIMARY_IFACE" ]; then
          for dev in /sys/class/net/*; do
            if [ -d "$dev" ]; then
              devname=$(basename "$dev")
              if [ "$devname" != "lo" ] && [ -f "$dev/address" ]; then
                cand_ip=$(ip -4 addr show dev "$devname" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -n1 || true)
                if [ -n "$cand_ip" ]; then
                  PRIMARY_IFACE="$devname"
                  MY_IP="$cand_ip"
                  break
                fi
              fi
            fi
          done
        fi

        PRIMARY_MAC=""
        if [ -n "$PRIMARY_IFACE" ] && [ -f "/sys/class/net/$PRIMARY_IFACE/address" ]; then
          PRIMARY_MAC=$(cat "/sys/class/net/$PRIMARY_IFACE/address" | tr '[:upper:]' '[:lower:]')
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

        # 2. Fallback to primary interface MAC address
        if [ -z "$NODE_HOSTNAME" ] && [ -n "$PRIMARY_MAC" ]; then
          NODE_HOSTNAME=$(echo "$PRIMARY_MAC" | tr ':' '-')
        fi

        # 3. Final fallback: dmidecode system UUID
        if [ -z "$NODE_HOSTNAME" ]; then
          SYS_UUID=$(dmidecode -s system-uuid 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
          NODE_HOSTNAME="node-$SYS_UUID"
        fi

        echo "==> Running Hardware Inspector for host: $NODE_HOSTNAME (MAC: $PRIMARY_MAC)..."
        ${lib.getExe pkgs.inspector} inspect > "$REPORT_FILE" 2>&1 || true

        # Ensure network block exists in report
        echo "network:" >> "$REPORT_FILE"
        echo "  hostname: $NODE_HOSTNAME" >> "$REPORT_FILE"
        echo "  primary_iface: ''${PRIMARY_IFACE:-unknown}" >> "$REPORT_FILE"
        echo "  primary_ip: ''${MY_IP:-unknown}" >> "$REPORT_FILE"
        echo "  primary_mac: ''${PRIMARY_MAC:-unknown}" >> "$REPORT_FILE"
        echo "  interfaces:" >> "$REPORT_FILE"
        ${pkgs.iproute2}/bin/ip -j addr | ${pkgs.jq}/bin/jq -r '.[] | "  - iface: " + .ifname + "\n    mac: " + (.address // "") + "\n    ips: " + ([(.addr_info[]? | .local)] | join(","))' >> "$REPORT_FILE" || true

        cp "$REPORT_FILE" "$LOG_FILE"

        # Discover Coordinator Server Target (from kernel cmdline or DNS/DHCP fallback)
        CMDLINE_SERVER=$(cat /proc/cmdline | grep -oP '(?:inspector|coordinator)\.server=\K\S+' | head -n1 || true)

        if [ -n "$CMDLINE_SERVER" ]; then
          COORDINATOR_SERVER="$CMDLINE_SERVER"
        else
          DNS_SERVER=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)
          DHCP_SERVER=$(grep -m1 -oP 'SERVER_ID=\K\S+' /run/systemd/netif/leases/* 2>/dev/null || grep -m1 -oP 'dhcp_server_identifier=\K\S+' /var/lib/dhcpcd/* 2>/dev/null || true)
          if [ -n "$DNS_SERVER" ] && [ "$DNS_SERVER" != "127.0.0.1" ]; then
            COORDINATOR_SERVER="http://$DNS_SERVER:8080"
          elif [ -n "$DHCP_SERVER" ]; then
            COORDINATOR_SERVER="http://$DHCP_SERVER:8080"
          elif [ -n "$PRIMARY_IFACE" ]; then
            GW_IP=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -n1 || true)
            if [ -n "$GW_IP" ]; then
              COORDINATOR_SERVER="http://$GW_IP:8080"
            else
              COORDINATOR_SERVER=""
            fi
          else
            COORDINATOR_SERVER=""
          fi
        fi

        # Normalize protocol prefix
        if [ -n "$COORDINATOR_SERVER" ] && [[ "$COORDINATOR_SERVER" != http* ]]; then
          COORDINATOR_SERVER="http://$COORDINATOR_SERVER"
        fi

        if [ -z "$COORDINATOR_SERVER" ]; then
          echo "========================================================================="
          echo "[ERROR] No Coordinator server target discovered (missing 'inspector.server=' or 'coordinator.server=' kernel arg)."
          echo "[INFO] Hardware report saved locally at: $LOG_FILE"
          echo "[INFO] SSH is ACTIVE. Node will remain powered on for manual inspection."
          echo "========================================================================="
          exit 1
        fi

        echo "==> Attempting HTTP POST report to $COORDINATOR_SERVER/api/reports?hostname=$NODE_HOSTNAME..."
        HTTP_RESPONSE=""
        for i in $(seq 1 5); do
          echo "==> Uploading hardware report (attempt $i/5)..."
          HTTP_RESPONSE=$(curl -s --connect-timeout 5 --max-time 20 -X POST \
            -H "Content-Type: application/x-yaml" \
            -H "X-Hostname: $NODE_HOSTNAME" \
            -H "X-MAC: $PRIMARY_MAC" \
            --data-binary @"$REPORT_FILE" \
            "$COORDINATOR_SERVER/api/reports?hostname=$NODE_HOSTNAME" || true)
          if [ -n "$HTTP_RESPONSE" ] && echo "$HTTP_RESPONSE" | jq -e . >/dev/null 2>&1; then
            echo "==> Hardware report uploaded successfully!"
            echo "==> Server response: $HTTP_RESPONSE"
            break
          fi
          sleep 2
        done

        CMDLINE_WIPE=$(cat /proc/cmdline | grep -oP '(?:inspector|coordinator)\.wipe=\K\S+' | head -n1 || true)
        WIPE_REQUESTED="false"
        if [ -n "$HTTP_RESPONSE" ] && echo "$HTTP_RESPONSE" | jq -e . >/dev/null 2>&1; then
          WIPE_REQUESTED=$(echo "$HTTP_RESPONSE" | jq -r '.wipe // false')
        fi

        if [ "$WIPE_REQUESTED" = "true" ] || [ "$CMDLINE_WIPE" = "1" ] || [ "$CMDLINE_WIPE" = "true" ]; then
          echo "==> WARNING: DISK WIPE REQUESTED! Running disk wipe..."
          WIPE_LOG="/var/log/wipe-$NODE_HOSTNAME-$(date +%s).log"
          ${lib.getExe pkgs.inspector} wipe --confirm > "$WIPE_LOG" 2>&1 || true

          for i in $(seq 1 5); do
            echo "==> Uploading wipe log to $COORDINATOR_SERVER/api/wipelog (attempt $i/5)..."
            WIPE_RES=$(curl -s --connect-timeout 5 --max-time 20 -X POST \
              -H "Content-Type: text/plain" \
              -H "X-Hostname: $NODE_HOSTNAME" \
              -H "X-MAC: $PRIMARY_MAC" \
              --data-binary @"$WIPE_LOG" \
              "$COORDINATOR_SERVER/api/wipelog?hostname=$NODE_HOSTNAME" || true)
            if [ -n "$WIPE_RES" ] && echo "$WIPE_RES" | jq -e . >/dev/null 2>&1; then
              echo "==> Wipe log uploaded successfully to Coordinator!"
              break
            fi
            sleep 2
          done

          echo "==> Storage wipe completed. Flushing buffers and powering off..."
          sync
          poweroff
        elif [ -n "$HTTP_RESPONSE" ] && echo "$HTTP_RESPONSE" | jq -e . >/dev/null 2>&1; then
          echo "==> Hardware inspection complete. Powering off..."
          sync
          poweroff
        else
          echo "========================================================================="
          echo "[ERROR] HTTP POST report upload failed or Coordinator server unreachable at $COORDINATOR_SERVER"
          echo "[INFO] Report saved locally at: $LOG_FILE"
          echo "[INFO] SSH is ACTIVE. Node will remain powered on for manual inspection."
          echo "========================================================================="
          exit 1
        fi
      '';

      serviceConfig = {
        Type = "oneshot";
      };
    };

    systemd.services.inspector-emergency = {
      description = "Emergency Diagnostics and SSH Keep-Alive for Inspector";
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = pkgs.writeShellScript "inspector-emergency" ''
          echo "========================================================================="
          echo "EMERGENCY FALLBACK: Inspector service encountered an error."
          echo "Network and SSH remain ACTIVE for manual triage."
          echo "Node IP: $(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -n1 || echo 'unknown')"
          echo "SSH Login: ssh root@<ip>"
          echo "Logs: journalctl -u inspector-report -e"
          echo "========================================================================="
        '';
      };
    };

    system.stateVersion = "25.11";
  };
}

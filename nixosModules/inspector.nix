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
        gptfdisk
        hostname
        iproute2
        jq
        parted
        systemd
        util-linux
      ];

      script = ''
        set -u

        REPORT_FILE="/tmp/inspector-report.yaml"
        LOG_FILE="/var/log/inspector-report.yaml"

        # Determine hostname (runtime hostname -> NixOS config hostname fallback)
        NODE_HOSTNAME=$(hostname 2>/dev/null || echo "")
        if [ -z "$NODE_HOSTNAME" ] || [ "$NODE_HOSTNAME" = "localhost" ]; then
          NODE_HOSTNAME="${configuredHostName}"
        fi

        echo "==> Running Hardware Inspector for host: $NODE_HOSTNAME..."
        ${lib.getExe pkgs.inspector} inspect > "$REPORT_FILE"
        cp "$REPORT_FILE" "$LOG_FILE"

        # Discover CNC Server Target (cmdline -> DHCP Gateway -> Default 10.211.0.10:8080)
        CMDLINE_SERVER=$(cat /proc/cmdline | grep -oP 'inspector.server=\K\S+' || true)
        GATEWAY_IP=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1 || true)

        if [ -n "$CMDLINE_SERVER" ]; then
          CNC_SERVER="$CMDLINE_SERVER"
        elif [ -n "$GATEWAY_IP" ]; then
          CNC_SERVER="$GATEWAY_IP:8080"
        else
          CNC_SERVER="10.211.0.10:8080"
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

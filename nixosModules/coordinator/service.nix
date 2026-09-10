# =====================================================================
# lab-setup: Coordinator Daemon Service Module
#
# Configures the coordinator FastAPI daemon, environment variables,
# state directory, restart triggers, and firewall port 8080.
# =====================================================================

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.coordinator;
in
{
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [
      8080 # Coordinator API & Talos config server
    ];

    systemd.services.coordinator = {
      description = "AI Village Cluster Coordinator (Netboot, Discovery & Talos Configs)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PORT = "8080";
        PYTHONUNBUFFERED = "1";
        CONFIGS_DIR = "/var/lib/tftpboot/configs";
        GATEWAY_IP = cfg.gateway;
        COORDINATOR_IP = cfg.ip;
        DNS_IP = cfg.ip;
        PRIVATE_SUBNET = cfg.privateSubnet;
        PUBLIC_SUBNET = cfg.publicSubnet;
        FLAKE_MACHINES_FILE = "${pkgs.writeText "flake-machines.json" (builtins.toJSON (
          lib.mapAttrs (name: m:
            let
              netIfaces = m.network-interfaces or { };
            in {
              name = m.name or name;
              controlPlane = m.controlPlane or false;
              nvidia = m.nvidia or false;
              macs = lib.filter (x: x != null) (
                lib.mapAttrsToList (_iface: attrs: attrs.mac or null) netIfaces
              );
              iface =
                let
                  ifaces = lib.mapAttrsToList (k: _v: k) netIfaces;
                in
                if ifaces != [ ] then lib.head ifaces else "eth0";
              pxe_ip = m.ip or null;
            }) cfg.machines
        ))}";
      } // (lib.optionalAttrs (cfg.talosSopsFile != null) {
        SECRETS_FILE = config.sops.secrets."talos-secrets".path;
      });

      restartTriggers = [
        (import ../../packages/coordinator { inherit pkgs; })
      ];

      serviceConfig = {
        ExecStart = "${(import ../../packages/coordinator { inherit pkgs; })}/bin/coordinator";
        Restart = "always";
        RestartSec = 5;
        StateDirectory = [
          "coordinator"
        ];
        StateDirectoryMode = "0755";
      };
    };
  };
}

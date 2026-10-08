# =====================================================================
# lab-setup: Coordinator Container Registry Mirrors Module
#
# Configures pull-through container registry mirrors, dynamic firewall
# port allocations, and precache service.
# =====================================================================

{
  config,
  lib,
  pkgs,
  inputs ? null,
  lab ? null,
  ...
}:

let
  cfg = config.lab.coordinator;
  labSafe = if lab != null then lab else { };
  inputsSafe = if inputs != null then inputs else { };

  distributionPkg = pkgs.distribution or pkgs.docker-distribution;
in
{
  options.lab.coordinator.registry = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = labSafe.coordinator.registry.enable or false;
      description = "Pull-through container registry mirrors on coordinator";
    };
    storageDir = lib.mkOption {
      type = lib.types.str;
      default = labSafe.coordinator.registry.storageDir or "/var/lib/coordinator/registries";
      description = "Storage directory on NVMe for cached container image layers";
    };
    providers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          remoteUrl = lib.mkOption { type = lib.types.str; };
          port = lib.mkOption { type = lib.types.port; };
        };
      });
      default = labSafe.coordinator.registry.providers or (import ../../talos/registries.nix);
      description = "Pull-through container registry providers";
    };
    precacheImages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        (labSafe.coordinator.registry.precacheImages or [ ])
        ++ (inputsSafe.workshops.workshopInfo.requiredImages or [ ]);
      description = "List of container images to pre-warm into local coordinator cache";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.registry.enable) {
    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_name: p: p.port) cfg.registry.providers;

    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (name: provider:
        let
          cleanName = lib.replaceStrings [ "." ] [ "-" ] name;
          configFile = pkgs.writeText "registry-${cleanName}.json" (builtins.toJSON {
            version = "0.1";
            log = {
              level = "info";
              fields = {
                service = "registry-${cleanName}";
              };
            };
            storage = {
              cache = {
                blobdescriptor = "inmemory";
              };
              filesystem = {
                rootdirectory = "${cfg.registry.storageDir}/${cleanName}";
              };
            };
            http = {
              addr = ":${toString provider.port}";
              headers = {
                X-Content-Type-Options = [ "nosniff" ];
              };
            };
            proxy = {
              remoteurl = provider.remoteUrl;
            };
          });
        in
        lib.nameValuePair "docker-registry-${cleanName}" {
          description = "Container Registry Mirror for ${name} (port ${toString provider.port})";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${distributionPkg}/bin/registry serve ${configFile}";
            Restart = "always";
            RestartSec = 5;
          };
        }
      ) cfg.registry.providers)

      (lib.mkIf (cfg.registry.precacheImages != [ ]) {
        coordinator-precache = {
          description = "Pre-cache Container Images into Coordinator Local Registry Mirrors";
          after = [ "network.target" ] ++ (map (name: "docker-registry-${lib.replaceStrings [ "." ] [ "-" ] name}.service") (lib.attrNames cfg.registry.providers));
          wants = (map (name: "docker-registry-${lib.replaceStrings [ "." ] [ "-" ] name}.service") (lib.attrNames cfg.registry.providers));
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.skopeo pkgs.curl pkgs.coreutils ];
          script = ''
            set -u
            echo "Waiting for registry mirrors to become responsive..."
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: provider: ''
              for i in {1..30}; do
                if curl -s -f "http://127.0.0.1:${toString provider.port}/v2/" >/dev/null 2>&1; then
                  echo "Registry ${name} on port ${toString provider.port} is ready"
                  break
                fi
                sleep 1
              done
            '') cfg.registry.providers)}

            TMPDIR=$(mktemp -d)
            trap 'rm -rf "$TMPDIR"' EXIT

            ${lib.concatMapStringsSep "\n" (img:
              let
                matchedProvider = lib.findFirst (name: lib.hasPrefix "${name}/" img) null (lib.attrNames cfg.registry.providers);
                fallbackProvider = if matchedProvider != null then matchedProvider else "docker.io";
                providerCfg = cfg.registry.providers.${fallbackProvider} or { port = 5001; };
                strippedImg =
                  if matchedProvider != null then
                    lib.removePrefix "${matchedProvider}/" img
                  else if lib.hasPrefix "docker.io/" img then
                    lib.removePrefix "docker.io/" img
                  else
                    img;
                finalPath =
                  if fallbackProvider == "docker.io" && !(lib.hasInfix "/" strippedImg) then
                    "library/${strippedImg}"
                  else
                    strippedImg;
              in ''
                echo "Pre-caching ${img} via 127.0.0.1:${toString providerCfg.port}/${finalPath}..."
                ${pkgs.skopeo}/bin/skopeo copy --all --insecure-policy --src-tls-verify=false "docker://127.0.0.1:${toString providerCfg.port}/${finalPath}" "dir:$TMPDIR/trash" || {
                  echo "Warning: failed to pre-cache ${img}"
                }
                rm -rf "$TMPDIR/trash"
              ''
            ) cfg.registry.precacheImages}
            echo "Pre-caching completed."
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
      })
    ];
  };
}

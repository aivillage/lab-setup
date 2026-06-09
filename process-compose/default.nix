{ inputs, ... }:
{
  perSystem =
    {
      config,
      lib,
      pkgs,
      system,
      ...
    }:
    let
      inherit (inputs.services-flake.lib) multiService;
      inherit (inputs) nix-kube-generators;
      kubelib = nix-kube-generators.lib { inherit pkgs; };
    in
    {
      process-compose.default =
        { config, lib, ... }:
        {
          options.lab = {
            globalDataDir = lib.mkOption {
              type = lib.types.str;
              default = ".data";
              description = "The global root directory for all lab state.";
            };
          };

          imports = [
            inputs.services-flake.processComposeModules.default
            (multiService ./tilt.nix)
            (multiService ./local_path_storage.nix)
            (multiService ./talos.nix)
            (multiService ./patches.nix)
            (multiService ./containers.nix)
          ];

          config =
            let
              patchesDir = "${config.lab.globalDataDir}/talos/patches";
            in
            {
              services = {
                # look in ./containers.nix for options
                containers."lab" = {
                  enable = true;
                  webserver = {
                    enable = true;
                    inherit patchesDir;
                  };
                  registries = {
                    enable = true;
                    providers = {
                      "docker.io" = {
                        remoteUrl = "https://registry-1.docker.io";
                        localPort = 5000;

                        dataDir = "${config.lab.globalDataDir}/registry";
                      };
                      "registry.k8s.io" = {
                        remoteUrl = "https://registry.k8s.io";
                        localPort = 5001;
                        dataDir = "${config.lab.globalDataDir}/registry";
                      };
                      "gcr.io" = {
                        remoteUrl = "https://gcr.io";
                        localPort = 5002;
                        dataDir = "${config.lab.globalDataDir}/registry";
                      };
                      "ghcr.io" = {
                        remoteUrl = "https://ghcr.io";
                        localPort = 5003;
                        dataDir = "${config.lab.globalDataDir}/registry";
                      };
                      "quay.io" = {
                        remoteUrl = "https://quay.io";
                        localPort = 5004;
                        dataDir = "${config.lab.globalDataDir}/registry";
                      };
                    };
                  };
                };

                patches."lab" = {
                  enable = true;
                  dataDir = patchesDir;
                  kubelib = kubelib;
                  webserverHost = "${config.services.containers."lab".webserver.host}:${
                    builtins.toString config.services.containers."lab".webserver.localPort
                  }";
                };

                # look in ./talos.nix for options
                talos = {
                  cluster = {
                    enable = true;
                    dataDir = "${config.lab.globalDataDir}/talos";
                    provisioner = "docker";
                    workers = {
                      count = 3;
                      cpus = "2.0";
                      memory = "2Gib";
                    };
                    registryMirrors = lib.mkIf config.services.containers."lab".registries.enable (
                      lib.mapAttrsToList (
                        name: cfg:
                        "${name}=http://${config.services.containers."lab".registries.host}:${toString cfg.localPort}"
                      ) config.services.containers."lab".registries.providers
                    );
                    configPatches = [
                      "${patchesDir}/bootstrap.yaml"
                    ];
                    docker = lib.mkIf (config.services.talos.cluster.provisioner == "docker") {
                      exposedPorts = "80:80/tcp,443:443/tcp";
                    };
                    # qemu provisioner is wip
                    qemu = lib.mkIf (config.services.talos.cluster.provisioner == "qemu") {
                      presets = [ "iso" ];
                    };
                  };
                };

                local_path_storage."storage" = {
                  enable = false;
                  kubeconfig = "${config.lab.globalDataDir}/talos/kubeconfig";
                };

                tilt = {
                  tilt = {
                    enable = false;
                    dataDir = "${config.lab.globalDataDir}/postgres";
                    runtimeInputs = [ ];
                    environment = {
                      KUBECONFIG = "${config.lab.globalDataDir}/talos/kubeconfig";
                      NIX_CONFIG = "experimental-features = nix-command flakes";
                      NIX_PATH = "nixpkgs=${pkgs.path}";
                    };
                  };
                };
              };

              settings.processes = {
                cluster.depends_on = {
                  lab.condition = "process_completed_successfully";
                  "webserver-talos-patches" = {
                    condition = "process_started";
                  };
                }
                // lib.optionalAttrs config.services.containers."lab".registries.enable (
                  lib.mapAttrs' (
                    name: cfg: lib.nameValuePair "registry-${name}" { condition = "process_started"; }
                  ) config.services.containers."lab".registries.providers
                );
              };

              # todo
              # storage.depends_on = {
              #   cluster.condition = "process_log_ready";
              # };
              #
              # tilt.depends_on = {
              #   storage.condition = "process_completed_successfully";
              #   cluster.condition = "process_log_ready";
              # };
            };
        };
    };
}

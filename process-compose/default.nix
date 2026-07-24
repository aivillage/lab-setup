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
          imports = [
            inputs.services-flake.processComposeModules.default
            (multiService ./tilt.nix)
            (multiService ./local-path-storage.nix)
            (multiService ./talos.nix)
            (multiService ./patches.nix)
            (multiService ./containers.nix)
          ];

          config =
            let
              patchesDir = "patches";
            in
            {
              services = {
                # look in ./containers.nix for all available options
                containers."lab" = {
                  enable = true;
                  webserver = {
                    enable = true;
                    inherit patchesDir;
                  };
                  registries = {
                    enable = true;
                    providers = {
                      "registry.k8s.io" = {
                        remoteUrl = "https://registry.k8s.io";
                        localPort = 5001;
                      };
                      "gcr.io" = {
                        remoteUrl = "https://gcr.io";
                        localPort = 5002;
                      };
                      "ghcr.io" = {
                        remoteUrl = "https://ghcr.io";
                        localPort = 5003;
                      };
                      "quay.io" = {
                        remoteUrl = "https://quay.io";
                        localPort = 5004;
                      };
                      "docker.io" = {
                        remoteUrl = "https://registry-1.docker.io";
                        localPort = 5005;
                      };
                    };
                  };
                };

                patches."lab" = {
                  enable = true;
                  dataDir = patchesDir;
                  kubelib = kubelib;
                  # you can pass this an attr set or raw yaml
                  dynamicPatch = ''
                    machine:
                      registries:
                        config:
                          ghcr.io:
                            auth:
                              auth: "base64encodedcredentials"
                      time:
                        bootTimeout: 2m
                  '';
                  webserverHost = "${config.services.containers."lab".webserver.host}:${
                    builtins.toString config.services.containers."lab".webserver.localPort
                  }";
                };

                # look in ./talos.nix for all avilable options
                talos.cluster = {
                  enable = true;
                  provisioner = "docker";
                  dataDir = "talos/";
                  workers = {
                    count = 3;
                    cpus = "2.0";
                    memory = "2Gib";
                  };
                  docker = lib.mkIf (config.services.talos.cluster.provisioner == "docker") { };
                  qemu = lib.mkIf (config.services.talos.cluster.provisioner == "qemu") {
                    useSudo = true;
                    presets = [ "iso" ];
                  };
                  configPatches = [
                    "${patchesDir}/cilium-loader.yaml"
                  ]
                  ++
                    lib.optionals
                      (
                        config.services.patches."lab".dynamicPatch != { }
                        && config.services.patches."lab".dynamicPatch != [ ]
                        && config.services.patches."lab".dynamicPatch != ""
                      )
                      [
                        "${patchesDir}/dynamic.yaml"
                      ];
                  registryMirrors = lib.mkIf config.services.containers."lab".registries.enable (
                    lib.mapAttrsToList (
                      name: cfg:
                      "${name}=http://${config.services.containers."lab".registries.host}:${toString cfg.localPort}"
                    ) config.services.containers."lab".registries.providers
                  );
                };

                local-path-storage."storage" = {
                  enable = true;
                  kubeconfig = "talos/kubeconfig";
                };

                tilt = {
                  tilt = {
                    enable = true;
                    dataDir = "postgres";
                    runtimeInputs = [ ];
                    environment = {
                      KUBECONFIG = "talos/kubeconfig";
                      NIX_CONFIG = "experimental-features = nix-command flakes";
                      NIX_PATH = "nixpkgs=${pkgs.path}";
                    };
                  };
                };
              };

              settings.processes = {
                cluster.depends_on = {
                  patches.condition = "process_completed_successfully";
                  "webserver-talos-patches" = {
                    condition = "process_started";
                  };
                }
                // lib.optionalAttrs config.services.containers."lab".registries.enable (
                  lib.mapAttrs' (
                    name: cfg: lib.nameValuePair "registry-${name}" { condition = "process_started"; }
                  ) config.services.containers."lab".registries.providers
                );

                storage.depends_on = {
                  cluster.condition = "process_log_ready";
                };

                tilt.depends_on = {
                  storage.condition = "process_completed_successfully";
                  cluster.condition = "process_log_ready";
                };

              };
            };
        };
    };
}

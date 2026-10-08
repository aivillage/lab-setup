# ═══════════════════════════════════════════════════════════════════
# talos/config.nix
#
# Three concerns, cleanly separated:
#   mkMachinePatch     — per-machine YAML patch (hostname, network, disk)
#   mkMachineConfig    — generates one machine's talos config from a
#                        patches directory (no baked-in patch list)
#   mkGeneratePatches  — builds cilium, nvidia, nfs, and model-store
#                        patches from lab parameters and writes them
#                        to a directory
#
{
  pkgs,
  lib,
  inputs ? { },
}:

let
  kubelib =
    if inputs ? nix-kube-generators then
      inputs.nix-kube-generators.lib { inherit pkgs; }
    else if
      inputs ? lab-setup && inputs.lab-setup ? inputs && inputs.lab-setup.inputs ? nix-kube-generators
    then
      inputs.lab-setup.inputs.nix-kube-generators.lib { inherit pkgs; }
    else
      null;

  # ── Per-machine patch: hostname + network + install ───────────
  mkMachinePatch =
    { machine, schematic ? null }:
    let
      installerImage = "factory.talos.dev/installer/__SCHEMATIC_ID__:${machine.version}";
      ifaces = machine.network-interfaces or { };
      explicitPrimary = lib.filterAttrs (_name: iface: (iface.primary or false) || (lib.elem (iface.role or "") [ "private" "cluster" ])) ifaces;
      primaryIfaceName =
        if explicitPrimary != { } then
          lib.head (lib.attrNames explicitPrimary)
        else if ifaces != { } then
          lib.head (lib.attrNames ifaces)
        else
          null;
      rawKeys = lib.attrNames ifaces;
      sortedOther = lib.sort (a: b:
        let
          aIsSfp = lib.hasInfix "f" a;
          bIsSfp = lib.hasInfix "f" b;
        in
          if aIsSfp != bIsSfp then !aIsSfp else a < b
      ) (lib.filter (n: n != primaryIfaceName) rawKeys);
      orderedIfaceNames = lib.optional (primaryIfaceName != null) primaryIfaceName ++ sortedOther;
      ifaceList =
        if (machine.bonding.enable or false) then
          let
            bondedPrivateIfaces = lib.filterAttrs (_name: iface: ((iface.role or "") == "private") || (iface.primary or false)) ifaces;
            bondedPrivateIfaceNames = lib.attrNames bondedPrivateIfaces;
            otherIfaceNames = lib.filter (n: !lib.elem n bondedPrivateIfaceNames) (lib.attrNames ifaces);
            bond0Obj = {
              interface = "bond0";
              dhcp = true;
              dhcpOptions = {
                routeMetric = 1024;
              };
              bond = {
                mode = machine.bonding.mode or "802.3ad";
                interfaces = bondedPrivateIfaceNames;
                miimon = machine.bonding.miimon or 100;
                updelay = machine.bonding.updelay or 200;
                downdelay = machine.bonding.downdelay or 200;
              };
            } // (
              if (machine.controlPlane or false) && (machine.clusterVip or "") != "" then {
                vip = {
                  ip = machine.clusterVip;
                };
              } else { }
            );
            otherList = map (name:
              let
                ifaceAttrs = ifaces.${name};
              in
              if (ifaceAttrs.role or "") == "disabled" || (ifaceAttrs.ignore or false) then {
                interface = name;
                ignore = true;
              } else if (ifaceAttrs.ip or "") != "" then {
                interface = name;
                dhcp = false;
                addresses = [ "${ifaceAttrs.ip}/24" ];
              } else {
                interface = name;
                dhcp = true;
                dhcpOptions = {
                  routeMetric = 2048;
                };
              }
            ) otherIfaceNames;
          in
          [ bond0Obj ] ++ otherList
        else
          lib.imap0 (idx: name:
            let
              ifaceAttrs = ifaces.${name};
              isPrimary = name == primaryIfaceName;
            in
            if (ifaceAttrs.role or "") == "disabled" || (ifaceAttrs.ignore or false) then {
              interface = name;
              ignore = true;
            } else if (ifaceAttrs.ip or "") != "" then
              {
                interface = name;
                dhcp = false;
                addresses = [ "${ifaceAttrs.ip}/24" ];
              }
              // (
                if isPrimary then {
                  routes = [
                    {
                      network = "0.0.0.0/0";
                      gateway =
                        if (machine.gateway or "") != "" then
                          machine.gateway
                        else
                          throw "[AI VILLAGE] Machine '${machine.name}' has static IP '${ifaceAttrs.ip}' but 'lab.gateway' is not defined in lab.nix.";
                      metric = 1024;
                    }
                  ];
                } else { }
              )
            else
              {
                interface = name;
                dhcp = true;
                dhcpOptions = {
                  routeMetric = if isPrimary then 1024 else 2048;
                };
              }
              // (
                if isPrimary && (machine.controlPlane or false) && (machine.clusterVip or "") != "" then {
                  vip = {
                    ip = machine.clusterVip;
                  };
                } else { }
              )
          ) orderedIfaceNames;

      tpmPresent = machine.tpm.present or false;
      osDiskConfig = machine.disks.os or { };
      modelsDisk = machine.disks.models or null;
      modelsDiskDev = if modelsDisk != null then modelsDisk.device or null else null;
      modelsDiskMount = if modelsDisk != null then modelsDisk.mount or "/var/models" else "/var/models";
      osDiskEncrypted = osDiskConfig.encrypted or false;
      encryptionProvider = osDiskConfig.provider or "tpm";

      encryptionConfig =
        if osDiskEncrypted then
          if encryptionProvider == "tpm" && tpmPresent then {
            state = {
              provider = "luks2";
              keys = [
                { nodeID = { }; }
                {
                  slot = 1;
                  tpm = { };
                }
              ];
            };
            ephemeral = {
              provider = "luks2";
              keys = [
                { nodeID = { }; }
                {
                  slot = 1;
                  tpm = { };
                }
              ];
            };
          } else {
            state = {
              provider = "luks2";
              keys = [
                { nodeID = { }; }
              ];
            };
            ephemeral = {
              provider = "luks2";
              keys = [
                { nodeID = { }; }
              ];
            };
          }
        else { };

      patchObj = {
        machine = {
          type = if machine.controlPlane then "controlplane" else "worker";
          network = {
            hostname = machine.name;
            nameservers = machine.upstreamDns;
          } // (if ifaceList != [ ] then { interfaces = ifaceList; } else { });
          time = {
            disabled = false;
            servers = machine.upstreamNtp;
          };
          kubelet = {
            nodeIP = {
              validSubnets = [ machine.clusterSubnet ];
            };
          };
          install = {
            image = installerImage;
            wipe = true;
          } // (
            if (osDiskConfig.device or null) != null then { disk = osDiskConfig.device; }
            else if (machine.diskSelector or null) != null then { diskSelector = machine.diskSelector; }
            else throw "Machine ${machine.name} must declare either disks.os.device or diskSelector."
          );
        }
        // (if encryptionConfig != { } then { systemDiskEncryption = encryptionConfig; } else { })
        // (lib.optionalAttrs (modelsDiskDev != null && modelsDiskDev != "") {
          disks = [
            {
              device = modelsDiskDev;
              partitions = [
                { mountpoint = modelsDiskMount; }
              ];
            }
          ];
        })
        // (lib.optionalAttrs ((machine.coordinatorIp or "") != "") {
          registries = {
            mirrors = (lib.mapAttrs (_name: p: {
              endpoints = [
                "http://${machine.coordinatorIp}:${toString p.port}"
                p.remoteUrl
              ];
            }) machine.registryMirrors) // {
              "factory.talos.dev" = {
                endpoints = [
                  "http://${machine.coordinatorIp}:5001"
                  "https://factory.talos.dev"
                ];
              };
            };
          };
        })
        // (lib.optionalAttrs (machine.nvidia or false) {
          kernel = {
            modules = [
              { name = "nvidia"; }
              { name = "nvidia_uvm"; }
              { name = "nvidia_drm"; }
              { name = "nvidia_modeset"; }
            ];
          };
          sysctls = {
            "net.core.bpf_jit_harden" = 1;
          };
          files = [
            {
              content = ''
                [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
                  runtime_type = "io.containerd.runc.v2"
              '';
              permissions = 420;
              path = "/etc/cri/conf.d/20-customization.part";
              op = "create";
            }
          ];
        });
      };
    in
    let
      patchFile = pkgs.writeText "${machine.name}-machine-patch.yaml" (builtins.toJSON patchObj);
    in
    patchFile // { inherit patchFile; };
  nvidiaPatch =
    if kubelib != null then import ../k8s/nvidia.nix { inherit pkgs kubelib; } else null;
  # ── Generate a patches directory ───────────────────────────
  mkGeneratePatches =
    {
      nfsServer ? "",
      nfsPath ? "/data",
      extraPatches ? [ ],
      coordinatorIp,
      webserverHost ? "http://${coordinatorIp}:8080/configs",
      bootstrapCNI ? null,
      k8sManifests ? [ ],
      talosPatches ? [ ],
      overrides ? { },
      k8sWorkshopHub ? null,
      k8sVllm ? null,
      lab ? { },
      machines ? { },
    }:
    let
      resolvePatch = name: defaultFile:
        if overrides ? ${name} then overrides.${name} else defaultFile;

      ciliumPatch =
        if kubelib != null then import ../k8s/cilium.nix { inherit pkgs kubelib; } else null;
      cniLoaderPatch = import ./cni-loader.nix {
        inherit pkgs;
        host = webserverHost;
        ciliumPatchName = if bootstrapCNI != null then "cni.yaml" else "cilium.yaml";
      };

      nvidiaPatches =
        if nvidiaPatch != null then
          [
            {
              name = "addons/nvidia-device-plugin.yaml";
              file = resolvePatch "nvidia-device-plugin" nvidiaPatch.k8sManifest;
            }
            {
              name = "addons/nvidia-helm.yaml";
              file = resolvePatch "nvidia-helm" nvidiaPatch.helmPatch;
            }
            {
              name = "addons/nvidia-runtime.yaml";
              file = resolvePatch "nvidia-runtime" nvidiaPatch.runtimeClassPatch;
            }
          ]
        else
          [ ];

      nfsPatch =
        if nfsServer != "" && kubelib != null then
          [
            {
              name = "addons/nfs.yaml";
              file = resolvePatch "nfs-storage" (import ../k8s/nfs.nix {
                inherit pkgs kubelib;
                server = nfsServer;
                path = nfsPath;
              });
            }
          ]
        else
          [ ];

      workshopHubPatch =
        if k8sWorkshopHub != null && (k8sWorkshopHub.enable or true) then
          [
            {
              name = "addons/workshop-hub.yaml";
              file = resolvePatch "workshop-hub" (import ../k8s/workshop-hub.nix {
                inherit pkgs lib machines lab;
                cfg = k8sWorkshopHub;
              });
            }
          ]
        else
          [ ];

      vllmPatch =
        if k8sVllm != null && (k8sVllm.enable or true) then
          [
            {
              name = "addons/vllm.yaml";
              file = resolvePatch "vllm" (import ../k8s/vllm.nix {
                inherit pkgs lib;
                cfg = k8sVllm;
              });
            }
          ]
        else
          [ ];

      workshopsPatch =
        if k8sWorkshopHub != null && (k8sWorkshopHub.enable or true) then
          [
            {
              name = "addons/workshops.yaml";
              file = resolvePatch "workshops" (import ../k8s/workshops.nix {
                inherit pkgs lib;
                workshops = k8sWorkshopHub.resolvedWorkshops or [ ];
              });
            }
          ]
        else
          [ ];

      # Process custom path items or overrides passed in talosPatches & k8sManifests
      customTalosPatches = map (m:
        if lib.isPath m || lib.isDerivation m then {
          name = "base-patches/${builtins.baseNameOf (toString m)}";
          file = m;
        } else if lib.isAttrs m && m ? name && m ? file then {
          name = "base-patches/${m.name}";
          file = m.file;
        } else if lib.isString m && overrides ? ${m} then {
          name = "base-patches/${builtins.baseNameOf (toString overrides.${m})}";
          file = overrides.${m};
        } else null
      ) (lib.filter (x: x != null) talosPatches);

      customK8sPatches = map (m:
        if lib.isPath m || lib.isDerivation m then {
          name = "addons/${builtins.baseNameOf (toString m)}";
          file = m;
        } else if lib.isAttrs m && m ? name && m ? file then {
          name = "addons/${m.name}";
          file = m.file;
        } else if lib.isString m && overrides ? ${m} then {
          name = "addons/${builtins.baseNameOf (toString overrides.${m})}";
          file = overrides.${m};
        } else null
      ) (lib.filter (x: x != null) k8sManifests);

      basePatches = [
        {
          name = "base-patches/schedule.yaml";
          file = pkgs.writeText "schedule.yaml" "cluster:\n  allowSchedulingOnControlPlanes: true\n";
        }
        {
          name = "base-patches/cni-loader.yaml";
          file = cniLoaderPatch;
        }
      ] ++ (lib.filter (x: x != null) customTalosPatches);

      cniManifest =
        if bootstrapCNI != null then
          {
            name = "cni.yaml";
            file = bootstrapCNI;
          }
        else if ciliumPatch != null then
          {
            name = "cilium.yaml";
            file = resolvePatch "cilium" ciliumPatch;
          }
        else null;

      addonPatches = [
        {
          name = "addons/apiserver-kubelet-rbac.yaml";
          file = resolvePatch "apiserver-rbac" ../k8s/apiserver-kubelet-rbac.yaml;
        }
      ]
      ++ lib.optional (cniManifest != null) cniManifest
      ++ nvidiaPatches
      ++ nfsPatch
      ++ workshopHubPatch
      ++ workshopsPatch
      ++ vllmPatch
      ++ extraPatches
      ++ (lib.filter (x: x != null) customK8sPatches);

      patches = basePatches ++ addonPatches;
    in
    pkgs.writeShellScriptBin "generate-patches" ''
      set -euo pipefail

      OUTPUT_DIR="''${1:-.cluster/patches}"
      mkdir -p "$OUTPUT_DIR/base-patches" "$OUTPUT_DIR/addons"

      echo "Generating shared patches → $OUTPUT_DIR"

      ${lib.concatMapStringsSep "\n" (p: ''
        cp -f ${p.file} "$OUTPUT_DIR/${p.name}"
      '') patches}

      echo "✅ ${toString (builtins.length patches)} patches written to $OUTPUT_DIR"
    '';

  # ── Generate a single machine's config ────────────────────────
  mkMachineConfig =
    {
      machine,
      clusterName,
      clusterEndpoint,
      talosVersion,
      schematic,
    }:
    let
      machinePatch = mkMachinePatch { inherit machine schematic; };
      outputType = if machine.controlPlane then "controlplane,talosconfig" else "worker";
    in
    pkgs.writeShellApplication {
      name = "generate-config";
      runtimeInputs = [
        pkgs.talosctl
        pkgs.coreutils
        pkgs.gnused
        pkgs.python3
      ];
      runtimeEnv = {
        TALOS_VERSION = if lib.hasPrefix "v" talosVersion then talosVersion else "v${talosVersion}";
        OUTPUT_TYPE = outputType;
        MACHINE_PATCH_FILE = "${machinePatch.patchFile or machinePatch}";
        MACHINE_NAME = machine.name;
        CLUSTER_NAME = clusterName;
        CLUSTER_ENDPOINT = clusterEndpoint;
        SCHEMATIC_FILE = "${schematic}";
        EXTRA_PATCHES = lib.concatStringsSep " " machine.extraPatches;
      };
      text = builtins.readFile ./scripts/generate-config.sh;
    };

in
{
  inherit mkGeneratePatches mkMachineConfig mkMachinePatch;
}

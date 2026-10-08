{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.vllm;

  modelSubmodule = lib.types.submodule {
    options = {
      enable = lib.mkEnableOption "vLLM model inference container";

      model = lib.mkOption {
        type = lib.types.str;
        description = "Model repository name or path (e.g. google/gemma-4-31B-it-qat-w4a16-ct)";
      };

      servedModelName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Served model name exposed via OpenAI API. Defaults to model name.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8000;
        description = "Port to expose the OpenAI-compatible API on";
      };

      gpu = lib.mkOption {
        type = lib.types.str;
        default = "all";
        description = "NVIDIA GPU device(s) to allocate via CDI (e.g. 0, 1, or all)";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "vllm/vllm-openai:gemma";
        description = "Container image for vLLM";
      };

      gpuMemoryUtilization = lib.mkOption {
        type = lib.types.str;
        default = "0.80";
        description = "Fraction of GPU memory to reserve for the model executor";
      };

      maxModelLen = lib.mkOption {
        type = lib.types.str;
        default = "65536";
        description = "Maximum context length";
      };

      modelsDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/models";
        description = "Host directory containing cached model weights";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "--enable-chunked-prefill" ];
        description = "Extra CLI arguments to pass to vLLM";
      };
    };
  };
in
{
  options.services.vllm = {
    enable = lib.mkEnableOption "vLLM Model Serving Engine";

    models = lib.mkOption {
      type = lib.types.attrsOf modelSubmodule;
      default = { };
      description = "Set of models to serve via vLLM containers";
    };
  };

  config = lib.mkIf (cfg.enable || cfg.models != { }) {
    virtualisation.oci-containers.backend = lib.mkDefault "podman";

    virtualisation.oci-containers.containers = lib.mapAttrs' (name: mCfg:
      let
        servedName = if mCfg.servedModelName != "" then mCfg.servedModelName else mCfg.model;
        modelTarget =
          if lib.hasPrefix "/" mCfg.model then
            mCfg.model
          else
            "${mCfg.modelsDir}/${mCfg.model}";
      in
      lib.nameValuePair "vllm-${name}" {
        inherit (mCfg) image;
        volumes = [
          "${mCfg.modelsDir}:${mCfg.modelsDir}"
        ];
        extraOptions = [
          "--device=nvidia.com/gpu=${mCfg.gpu}"
          "--ipc=host"
          "--network=host"
        ];
        cmd = [
          "--model" modelTarget
          "--host" "0.0.0.0"
          "--port" (toString mCfg.port)
          "--served-model-name" servedName
          "--max-model-len" mCfg.maxModelLen
          "--gpu-memory-utilization" mCfg.gpuMemoryUtilization
        ] ++ mCfg.extraArgs;
      }
    ) (lib.filterAttrs (_: m: m.enable) cfg.models);

    systemd.services = lib.mapAttrs' (name: mCfg:
      lib.nameValuePair "podman-vllm-${name}" {
        after = [ "nvidia-container-toolkit-cdi-generator.service" ];
        wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
      }
    ) (lib.filterAttrs (_: m: m.enable) cfg.models);
  };
}

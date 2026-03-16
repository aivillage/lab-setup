# nix/dev_shell/vllm.nix
# vLLM Service Module for process-compose
{ pkgs, lib, config, name, ... }:
let
  inherit (lib) types mkOption mkIf;

  # Detect GPU type at runtime
  detectGpuScript = pkgs.writeShellScript "detect-gpu" ''
    if [[ "$OSTYPE" == "darwin"* ]]; then
      echo "metal"
    else
      if command -v lspci >/dev/null 2>&1; then
        if lspci | grep -i "vga\|3d\|display" | grep -iq "nvidia"; then
          echo "nvidia"
        elif lspci | grep -i "vga\|3d\|display" | grep -iq "amd\|radeon"; then
          echo "amd"
        else
          echo "cpu"
        fi
      else
        echo "cpu"
      fi
    fi
  '';

  # Base Docker arguments (common to all platforms)
  baseDockerArgs = [
    "docker"
    "run"
    "--rm"
    "--name" config.containerName
    "-p" "${toString config.port}:8000"
    "-v" "${config.dataDir}:/root/.cache/huggingface"
    "--ipc=host"
  ];

  # GPU-specific arguments
  nvidiaGpuArgs = [ "--gpus" "all" ];
  
  amdGpuArgs = [ 
    "--device" "/dev/kfd"
    "--device" "/dev/dri"
    "--group-add" "video"
    "--cap-add=SYS_PTRACE"
    "--security-opt" "seccomp=unconfined"
  ];
  
  metalArgs = [
    "-v" "/tmp:/tmp"  # Metal needs tmp directory
  ];

  # Additional environment variables per platform
  amdEnvVars = [
    "-e" "HSA_OVERRIDE_GFX_VERSION=11.0.0"  # May need adjustment per GPU
  ];

  # Docker images per platform
  nvidiaImage = config.image;
  amdImage = config.rocmImage;
  metalImage = config.image;
  cpuImage = config.image;

  # Script to start vLLM container with automatic GPU detection
  startCommand = pkgs.writeShellApplication {
    name = "start-vllm";
    runtimeInputs = with pkgs; [ docker coreutils pciutils ];
    
    text = ''
      set -euo pipefail
      
      echo "🚀 Starting vLLM service..."
      
      # Read token from .envhost at runtime
      if [ ! -f .envhost ]; then
        echo "✗ .envhost file not found"
        exit 1
      fi
      
      set -a
      # shellcheck source=/dev/null
      source .envhost
      set +a
      
      if [ -z "''${HF_TOKEN:-}" ]; then
        echo "✗ HF_TOKEN not found in .envhost"
        exit 1
      fi
      
      # Ensure data directory exists
      mkdir -p "${config.dataDir}"
      
      # Detect GPU type
      GPU_TYPE=$(${detectGpuScript})
      
      echo "ℹ Model: ${config.model}"
      echo "ℹ Port: ${toString config.port}"
      echo "ℹ Data dir: ${config.dataDir}"
      echo "ℹ Detected GPU type: $GPU_TYPE"
      echo ""
      
      # Build command based on GPU type
      case "$GPU_TYPE" in
        nvidia)
          echo "🎮 Using NVIDIA GPU acceleration"
          echo "ℹ Image: ${nvidiaImage}"
          
          exec ${lib.escapeShellArgs (baseDockerArgs ++ nvidiaGpuArgs ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e "HF_TOKEN=$HF_TOKEN" \
               ${lib.escapeShellArgs ([ nvidiaImage "--model" config.model ] ++ config.vllmArgs)}
          ;;
        amd)
          echo "🎮 Using AMD GPU acceleration (ROCm)"
          echo "ℹ Image: ${amdImage}"
          echo "${lib.escapeShellArgs (baseDockerArgs ++ amdGpuArgs ++ amdEnvVars ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e HF_TOKEN=$HF_TOKEN \
               ${lib.escapeShellArgs ([amdImage "python3" "-m" "vllm.entrypoints.openai.api_server" "--model" config.model] ++ config.vllmArgs)}"
          
          # FIX: Split args. Pass runtime -e *before* the image.
          exec ${lib.escapeShellArgs (baseDockerArgs ++ amdGpuArgs ++ amdEnvVars ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e HF_TOKEN="$HF_TOKEN" \
               ${lib.escapeShellArgs ([amdImage "python3" "-m" "vllm.entrypoints.openai.api_server" "--model" config.model] ++ config.vllmArgs)}
          ;;
        metal)
          echo "🍎 Using Apple Metal acceleration"
          echo "ℹ Image: ${metalImage}"
          
          exec ${lib.escapeShellArgs (baseDockerArgs ++ metalArgs ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e "HF_TOKEN=$HF_TOKEN" \
               ${lib.escapeShellArgs ([ metalImage "--model" config.model ] ++ config.vllmArgs)}
          ;;
        cpu)
          echo "⚠️  No GPU detected, using CPU only"
          echo "ℹ Image: ${cpuImage}"

          echo "${lib.escapeShellArgs (baseDockerArgs ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e HF_TOKEN=$HF_TOKEN \
               ${lib.escapeShellArgs ([ cpuImage "--model" config.model ] ++ config.vllmArgs)}"
          
          exec ${lib.escapeShellArgs (baseDockerArgs ++ lib.concatMap (env: [ "-e" env ]) config.extraEnv)} \
               -e "HF_TOKEN=$HF_TOKEN" \
               ${lib.escapeShellArgs ([ cpuImage "--model" config.model ] ++ config.vllmArgs)}
          ;;
        *)
          echo "✗ Unknown GPU type: $GPU_TYPE"
          exit 1
          ;;
      esac
    '';
  };

  # Cleanup script
  cleanupScript = ''
    set +e
    echo "🧹 Stopping vLLM container..."
    docker stop "${config.containerName}" 2>/dev/null || true
    echo "✓ vLLM stopped"
  '';

in
{
  options = {

    containerName = mkOption {
      type = types.str;
      default = "vllm-${name}";
      description = "Docker container name";
    };

    image = mkOption {
      type = types.str;
      default = "vllm/vllm-openai:latest";
      description = "Docker image to use for NVIDIA/CPU/Metal";
    };

    rocmImage = mkOption {
      type = types.str;
      default = "rocm/vllm:latest";
      description = "Docker image to use for AMD ROCm";
    };

    model = mkOption {
      type = types.str;
      description = "Model to load";
    };

    port = mkOption {
      type = types.int;
      default = 8000;
      description = "Port to expose vLLM API on";
    };
    
    vllmArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional arguments to pass to vLLM";
    };

    extraEnv = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional environment variables";
    };
  };

  config = mkIf config.enable {
    outputs.settings.processes."${name}" = {
      command = "${startCommand}/bin/start-vllm";
      
      ready_log_line = "Application startup complete";
    };
  };
}
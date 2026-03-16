  
{ config, lib, name, pkgs, ... }:

let
  inherit (lib) types mkOption;

  localPathStorageChart = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml";
    sha256 = "sha256-58p5FKeNu8INKSAaxGpslZVf/BTP51/yrmA642z3bT4=";
  };

  # This creates a shell script in the Nix store that contains all our commands.
  # It's the best way to run a sequence of commands in process-compose.
  setupScript = pkgs.writeShellApplication {
    name = "install-local-path";
    
    # This ensures helm and kubectl are available in the script's PATH at runtime.
    runtimeInputs = [
      config.kubectlPackage
    ];

    text = ''
      # This makes the script exit immediately if any command fails.
      set -euo pipefail

      kubectl apply -f ${(lib.escapeShellArg localPathStorageChart)}
      kubectl label namespace local-path-storage pod-security.kubernetes.io/enforce=privileged
      kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    '';
  };

in
{
  # These are the configuration options you can set in your flake.nix
  options = {
    kubectlPackage = mkOption {
      type = types.package;
      default = pkgs.kubectl;
      description = "The kubectl package to use.";
    };
    kubeconfig = mkOption {
      type = types.str;
      description = "Path to the kubeconfig file for the service.";
    };
  };

  # This is the configuration that gets turned into a process-compose entry.
  config = {
    outputs.settings.processes."${name}" = {
      # We run the script we defined above.
      command = "${setupScript}/bin/install-local-path";
      environment = {
        # Pass the KUBECONFIG path into the script's environment.
        KUBECONFIG = config.kubeconfig;
      };
    };
  };
}
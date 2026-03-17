{ config, lib, name, pkgs, ... }:
let
  inherit (lib) types;


  startScript = pkgs.writeShellApplication {
    name = "tilt-script";
    
    # This ensures helm and kubectl are available in the script's PATH at runtime.
    runtimeInputs = [
      config.kubectlPackage
    ] ++ config.runtimeInputs;

    text = ''
      ${lib.getExe config.package} up --host ${config.hostname}
    '';
  };
in
{
  options = {
    package = lib.mkOption {
      type = types.package;
      default = pkgs.tilt;
      defaultText = lib.literalExpression "pkgs.tilt";
      description = "The tilt package to use";
    };
    runtimeInputs = lib.mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Extra packages tilt may need to execute";
    };
    hostname = lib.mkOption {
      type = types.str;
      default = "localhost";
      description = "Extra packages tilt may need to execute";
    };
    environment = lib.mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Extra packages tilt may need to execute";
    };
    kubectlPackage = lib.mkOption {
      type = types.package;
      default = pkgs.kubectl;
      description = "The kubectl package to use.";
    };
    kubeconfig = lib.mkOption {
      type = types.str;
      default = "kubeconfig";
      description = "The location of the kubeconfig";
    };

  };
  
  config =
  {
    outputs.settings = {
      processes = {        
        "${name}" = {
          command = startScript;
          
          environment = config.environment;
        };
      };
    };
  };
}
{ inputs, ... }:
let
  dgxSpark = inputs.dgx-spark or inputs.lab-setup.inputs.dgx-spark;
in
{
  imports = [
    dgxSpark.nixosModules.dgx-spark
  ];
  nixpkgs.overlays = [
    dgxSpark.overlays.fixes
  ];
}

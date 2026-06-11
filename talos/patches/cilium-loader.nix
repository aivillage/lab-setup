# the cilium patch is too large to pass via --config-patch @ method
# instead served via nginx container
# todo: remove docker as a requirement for qemu provisioner
{
  pkgs,
  host,
  ciliumPatchName,
}:
let
  patchData = {
    cluster = {
      network = {
        cni = {
          name = "custom";
          urls = [
            "${host}/${ciliumPatchName}"
          ];
        };
      };
      proxy = {
        disabled = true;
      };
    };
  };

in

(pkgs.formats.yaml { }).generate "cilium-loader.yaml" patchData

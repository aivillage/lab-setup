{
  pkgs,
  manifests ? [ "cilium" ],
  host,
}:
let
  manifestUrls = builtins.map (name: "${host}/${name}.yaml") manifests;

  patchData = {
    cluster = {
      network = {
        cni = {
          name = "custom";
          urls = manifestUrls;
        };
      };
      proxy = {
        disabled = true;
      };
    };
  };

in

(pkgs.formats.yaml { }).generate "talos-cilium-patch.yaml" patchData

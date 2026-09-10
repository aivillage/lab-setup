{
  pkgs,
  coordinator ? (args.coordinator or "127.0.0.1"),
  controlVip ? (args.vip or args.controlVip or ""),
  endpoint ? (if controlVip != "" then "https://${controlVip}:6443" else ""),
  machines ? { },
}@args:

let
  machinesJson = builtins.toJSON (
    let
      raw = if pkgs.lib.isAttrs machines then (machines.machines or machines) else { };
    in
      pkgs.lib.mapAttrs (name: m:
        let
          mCfg = m.machine or m;
          netIfaces = mCfg.network-interfaces or { };
        in {
          name = mCfg.name or name;
          ip = m.primaryIp or mCfg.ip or null;
          controlPlane = mCfg.controlPlane or false;
          nvidia = mCfg.nvidia or false;
          disks = mCfg.disks or null;
          diskSelector = mCfg.diskSelector or null;
          tpm = mCfg.tpm or null;
          network-interfaces = netIfaces;
        }) raw
    );

  runtimeBinaries = [
    pkgs.talosctl
    pkgs.kubectl
    pkgs.kubernetes-helm
    pkgs.k9s
    pkgs.cilium-cli
    pkgs.sops
    pkgs.age
    pkgs.openssl
    pkgs.curl
    pkgs.util-linux
    pkgs.coreutils
  ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
    pkgs.iproute2
    pkgs.nettools
  ];

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    typer
    rich
    httpx
    pydantic
    pyyaml
  ]);
in
pkgs.stdenv.mkDerivation {
  pname = "cluster-cli";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/libexec $out/bin
    cp -r src/cluster_cli $out/libexec/

    makeWrapper ${pythonEnv}/bin/python3 $out/bin/cluster \
      --set PYTHONPATH "$out/libexec" \
      --add-flags "-m cluster_cli.cli" \
      --set CLUSTER_MACHINES_JSON '${machinesJson}' \
      --set CLUSTER_COORDINATOR_HOST "${if coordinator != null then coordinator else "127.0.0.1"}" \
      --set CLUSTER_CONTROL_VIP "${controlVip}" \
      --set CLUSTER_ENDPOINT "${endpoint}" \
      --prefix PATH : ${pkgs.lib.makeBinPath runtimeBinaries}
  '';

  meta = {
    description = "AI Village Unified Cluster Management CLI";
    mainProgram = "cluster";
  };
}

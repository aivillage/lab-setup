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
        netIfaces = mCfg.network-interfaces or mCfg.networkInterfaces or { };
      in {
        name = mCfg.name or m.name or name;
        ip = m.primaryIp or mCfg.ip or (m.ip or null);
        controlPlane = mCfg.controlPlane or (m.controlPlane or false);
        nvidia = mCfg.nvidia or (m.nvidia or false);
        osDisk = mCfg.osDisk or (m.osDisk or null);
        diskSelector = mCfg.diskSelector or (m.diskSelector or null);
        networkInterfaces = netIfaces;
      }) raw
  );

  runtimeBinaries = [
    pkgs.python3
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
in
pkgs.stdenv.mkDerivation {
  pname = "cluster-cli";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin

    # 1. Install main Python cluster CLI
    install -Dm755 cluster.py $out/bin/.cluster-wrapped

    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/cluster \
      --add-flags "$out/bin/.cluster-wrapped" \
      --set CLUSTER_MACHINES_JSON '${machinesJson}' \
      --set CLUSTER_COORDINATOR_HOST "${coordinator}" \
      --set CLUSTER_CONTROL_VIP "${controlVip}" \
      --set CLUSTER_ENDPOINT "${endpoint}" \
      --prefix PATH : ${pkgs.lib.makeBinPath runtimeBinaries}

    # 2. Install legacy alias symlinks
    makeWrapper $out/bin/cluster $out/bin/cluster-status --add-flags "status"
    makeWrapper $out/bin/cluster $out/bin/cluster-wakeup --add-flags "wakeup"
    makeWrapper $out/bin/cluster $out/bin/cluster-shutdown --add-flags "shutdown"
    makeWrapper $out/bin/cluster $out/bin/cluster-pull-secrets --add-flags "pull-secrets"
    makeWrapper $out/bin/cluster $out/bin/cluster-discover --add-flags "discover"
  '';

  meta = {
    description = "AI Village Unified Cluster Management CLI";
    mainProgram = "cluster";
  };
}

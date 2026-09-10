import os
import shlex
import subprocess
from typing import List
from cluster_cli.config import get_talosconfig_path, is_local_host
from cluster_cli.views.console import print_error


def run_talosctl(
    args: List[str], coordinator_host: str = ""
) -> subprocess.CompletedProcess:
    """Executes talosctl locally or over SSH via coordinator."""
    if coordinator_host and not is_local_host(coordinator_host):
        remote_cmd = (
            "talosctl --talosconfig /var/lib/coordinator/talos/talosconfig "
            + " ".join(shlex.quote(str(a)) for a in args)
        )
        try:
            return subprocess.run(
                [
                    "ssh",
                    "-o",
                    "ConnectTimeout=4",
                    "-o",
                    "StrictHostKeyChecking=no",
                    f"admin@{coordinator_host}",
                    remote_cmd,
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
        except Exception as e:
            err = f"talosctl SSH execution failed ({coordinator_host}): {e}"
            print_error(err)
            return subprocess.CompletedProcess(args=args, returncode=1, stdout="", stderr=err)

    tc = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
    cmd = ["talosctl"]
    if os.path.isfile(tc):
        cmd.extend(["--talosconfig", tc])
    cmd.extend([str(a) for a in args])
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except Exception as e:
        err = f"talosctl local execution failed: {e}"
        print_error(err)
        return subprocess.CompletedProcess(args=cmd, returncode=1, stdout="", stderr=err)


def check_etcd_health(control_plane_ip: str, coordinator_host: str = "") -> bool:
    """Checks whether ETCD cluster is initialized and healthy."""
    if not control_plane_ip:
        return False
    try:
        res = run_talosctl(
            ["etcd", "members", "--endpoints", control_plane_ip, "--nodes", control_plane_ip],
            coordinator_host=coordinator_host,
        )
        if res.returncode == 0 and ("https://" in res.stdout or "control" in res.stdout):
            return True
        if res.returncode != 0 and res.stderr:
            err_lower = res.stderr.lower()
            if any(k in err_lower for k in ("certificate", "tls", "unauthorized", "fatal", "timed out")):
                print_error(f"talosctl etcd health error for {control_plane_ip}: {res.stderr.strip()}")
    except Exception as e:
        print_error(f"Failed to check etcd health on {control_plane_ip}: {e}")
    return False


def shutdown_node(
    ip: str, coordinator_host: str = ""
) -> subprocess.CompletedProcess:
    """Sends forced shutdown command to target node."""
    if coordinator_host and not is_local_host(coordinator_host):
        cmd = [
            "ssh",
            "-o",
            "ConnectTimeout=8",
            "-o",
            "StrictHostKeyChecking=no",
            f"admin@{coordinator_host}",
            f"talosctl --talosconfig /var/lib/coordinator/talos/talosconfig -e {ip} -n {ip} shutdown --force",
        ]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
            if res.returncode != 0:
                err_lower = (res.stderr or "").lower()
                if any(
                    k in err_lower
                    for k in (
                        "connection reset",
                        "broken pipe",
                        "closed",
                        "eof",
                        "connection lost",
                        "timeout",
                        "transport",
                        "refused",
                        "unavailable",
                        "deadline exceeded",
                        "socket",
                    )
                ):
                    return subprocess.CompletedProcess(
                        args=cmd,
                        returncode=0,
                        stdout=res.stdout,
                        stderr="Node disconnected during power-down",
                    )
            return res
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(
                args=cmd,
                returncode=0,
                stdout="",
                stderr="Node disconnected during power-down",
            )
        except Exception as e:
            err = f"talosctl SSH shutdown failed ({ip}): {e}"
            print_error(err)
            return subprocess.CompletedProcess(args=cmd, returncode=1, stdout="", stderr=err)

    tc = get_talosconfig_path() or "/var/lib/coordinator/talos/talosconfig"
    cmd = ["talosctl"]
    if os.path.isfile(tc):
        cmd.extend(["--talosconfig", tc])
    cmd.extend(["--endpoints", ip, "--nodes", ip, "shutdown", "--force"])
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if res.returncode != 0:
            err_lower = (res.stderr or "").lower()
            if any(
                k in err_lower
                for k in (
                    "connection reset",
                    "broken pipe",
                    "closed",
                    "eof",
                    "connection lost",
                    "timeout",
                    "transport",
                    "refused",
                    "unavailable",
                    "deadline exceeded",
                    "socket",
                )
            ):
                return subprocess.CompletedProcess(
                    args=cmd,
                    returncode=0,
                    stdout=res.stdout,
                    stderr="Node disconnected during power-down",
                )
        return res
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            args=cmd,
            returncode=0,
            stdout="",
            stderr="Node disconnected during power-down",
        )
    except Exception as e:
        err = f"talosctl local shutdown failed ({ip}): {e}"
        print_error(err)
        return subprocess.CompletedProcess(args=cmd, returncode=1, stdout="", stderr=err)

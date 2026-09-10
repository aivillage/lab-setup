import json
import shlex
import subprocess
from typing import Any, Dict, List, Optional, Tuple
import httpx

from cluster_cli.config import get_coordinator_host, is_local_host
from cluster_cli.views.console import print_error, print_warning


class CoordinatorClient:
    """Typed client for interacting with the AI Village Cluster Coordinator API."""

    def __init__(self, coordinator_host: Optional[str] = None, port: int = 8080):
        self.coordinator_host = coordinator_host or get_coordinator_host()
        self.port = port
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.is_local = is_local_host(self.coordinator_host)

    def _extract_error(self, code: int, body: str) -> str:
        """Extracts detail or message from response body or formats error string."""
        if not body:
            return f"HTTP {code}" if code > 0 else "Connection failed or timed out"
        try:
            data = json.loads(body)
            if isinstance(data, dict):
                if "detail" in data:
                    return f"HTTP {code}: {data['detail']}" if code > 0 else str(data["detail"])
                if "message" in data:
                    return f"HTTP {code}: {data['message']}" if code > 0 else str(data["message"])
        except Exception:
            pass
        return f"HTTP {code}: {body.strip()}" if code > 0 else body.strip()

    def request(
        self,
        path: str,
        method: str = "GET",
        data: Optional[bytes] = None,
        json_data: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
        timeout: float = 8.0,
    ) -> Tuple[int, str]:
        """Unified API dispatcher: direct HTTPX client on localhost, or SSH tunnel when remote."""
        hdrs = {"User-Agent": "cluster-cli/1.0"}
        if headers:
            hdrs.update(headers)

        if self.is_local:
            try:
                with httpx.Client(base_url=self.base_url, timeout=timeout) as client:
                    resp = client.request(
                        method=method,
                        url=path,
                        content=data,
                        json=json_data,
                        headers=hdrs,
                    )
                    return resp.status_code, resp.text
            except httpx.HTTPStatusError as e:
                return e.response.status_code, e.response.text
            except Exception as e:
                return -1, str(e)
        else:
            # Tunnel via SSH to localhost:8080 on the coordinator host
            curl_args = ["curl", "-s", "-w", "__HTTP__:%{http_code}", "-X", method]
            for k, v in hdrs.items():
                curl_args.extend(["-H", shlex.quote(f"{k}: {v}")])
            if json_data is not None:
                json_bytes = json.dumps(json_data)
                curl_args.extend(["-H", shlex.quote("Content-Type: application/json")])
                curl_args.extend(["--data-binary", shlex.quote(json_bytes)])
            elif data:
                data_str = data.decode("utf-8", errors="ignore")
                curl_args.extend(["--data-binary", shlex.quote(data_str)])
            curl_args.append(shlex.quote(f"http://127.0.0.1:{self.port}{path}"))

            remote_cmd = " ".join(curl_args)
            ssh_cmd = [
                "ssh",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "StrictHostKeyChecking=no",
                "-A",
                f"admin@{self.coordinator_host}",
                remote_cmd,
            ]
            try:
                res = subprocess.run(
                    ssh_cmd, capture_output=True, text=False, timeout=timeout + 5
                )
                if res.returncode == 0:
                    raw = res.stdout
                    if b"__HTTP__:" in raw:
                        body_bytes, status_part = raw.rsplit(b"__HTTP__:", 1)
                        code_str = status_part.strip().decode(errors="ignore")
                        if code_str.isdigit():
                            return int(code_str), body_bytes.decode("utf-8", errors="replace")
                    return 200, raw.decode("utf-8", errors="replace")
                else:
                    return -1, res.stderr.decode(
                        "utf-8", errors="replace"
                    ).strip() or "SSH execution failed"
            except Exception as e:
                return -1, str(e)

    def get_status(self) -> Dict[str, Any]:
        """Fetches status data from /api/status."""
        code, body = self.request("/api/status", timeout=4.0)
        if code == 200 and body:
            try:
                return json.loads(body)
            except Exception as e:
                print_error(f"Failed to parse Coordinator status response: {e}")
                return {}
        err_msg = self._extract_error(code, body)
        print_error(f"Failed to fetch Coordinator status from {self.coordinator_host}: {err_msg}")
        return {}

    def get_wipe_log(self, target: str) -> Tuple[int, str]:
        """Fetches last wipe log for node."""
        code, body = self.request(f"/api/wipelog?node={target}", timeout=6.0)
        if code not in (200, 404):
            err_msg = self._extract_error(code, body)
            print_error(f"Failed to fetch wipe log for '{target}': {err_msg}")
        return code, body

    def get_wipelog(self, target: str) -> Tuple[int, str]:
        """Alias for get_wipe_log."""
        return self.get_wipe_log(target)

    def send_wipe_request(self, target: str, requested: bool) -> Tuple[bool, str]:
        """Sends wipe request toggle."""
        payload = {"target": target, "requested": requested}
        code, body = self.request(
            "/api/wipe",
            method="POST",
            json_data=payload,
            headers={"Content-Type": "application/json"},
        )
        if code == 200:
            try:
                data = json.loads(body)
                return True, data.get("status", "success")
            except Exception as e:
                print_warning(f"Failed to parse wipe response JSON: {e}")
                return True, "success"
        err_msg = self._extract_error(code, body)
        print_error(f"Failed to send wipe request for '{target}': {err_msg}")
        return False, err_msg

    def set_wipe_request(self, target: str) -> Tuple[bool, str]:
        """Requests disk wipe for target node."""
        return self.send_wipe_request(target, requested=True)

    def cancel_wipe_request(self, target: str) -> Tuple[bool, str]:
        """Cancels disk wipe for target node."""
        return self.send_wipe_request(target, requested=False)

    def mark_installed(self, target: str, installed: bool = True) -> Tuple[bool, str]:
        """Marks a node as installed in coordinator wipe data."""
        payload = {"target": target, "installed": installed}
        code, body = self.request(
            "/api/installed",
            method="POST",
            json_data=payload,
            headers={"Content-Type": "application/json"},
        )
        if code == 200:
            try:
                data = json.loads(body)
                return True, data.get("status", "success")
            except Exception as e:
                print_warning(f"Failed to parse installed response JSON: {e}")
                return True, "success"
        err_msg = self._extract_error(code, body)
        print_error(f"Failed to mark node '{target}' installed={installed}: {err_msg}")
        return False, err_msg

    def get_discovered_nix(self) -> Tuple[int, str]:
        """Fetches dynamically generated machines.nix."""
        code, body = self.request("/api/discovered/machines.nix", timeout=6.0)
        if code != 200:
            err_msg = self._extract_error(code, body)
            print_error(f"Failed to fetch discovered machines.nix: {err_msg}")
        return code, body

    def get_discovered_nodes(self) -> List[Dict[str, Any]]:
        """Fetches discovered nodes list."""
        code, body = self.request("/api/discovered", timeout=4.0)
        if code == 200 and body:
            try:
                data = json.loads(body)
                return data.get("nodes", [])
            except Exception as e:
                print_error(f"Failed to parse discovered nodes JSON: {e}")
                return []
        err_msg = self._extract_error(code, body)
        print_error(f"Failed to fetch discovered nodes: {err_msg}")
        return []

    def get_reports(self, target: Optional[str] = None) -> Tuple[int, str]:
        """Fetches reports list or single report."""
        path = f"/api/reports?node={target}" if target else "/api/reports"
        code, body = self.request(path, timeout=6.0)
        if code not in (200, 404):
            err_msg = self._extract_error(code, body)
            print_error(f"Failed to fetch hardware reports: {err_msg}")
        return code, body

    def get_config(self, conf_file: str) -> Tuple[int, str]:
        """Fetches rendered Talos configuration YAML."""
        code, body = self.request(f"/configs/{conf_file}", timeout=15.0)
        if code not in (200, 404, 403):
            err_msg = self._extract_error(code, body)
            print_error(f"Failed to fetch config '{conf_file}': {err_msg}")
        return code, body

    def purge_state(self) -> Tuple[int, str]:
        """Purges coordinator state."""
        code, body = self.request("/api/purge", method="POST", timeout=8.0)
        if code != 200:
            err_msg = self._extract_error(code, body)
            print_error(f"Failed to purge coordinator state: {err_msg}")
        return code, body

    def purge(self) -> Tuple[int, str]:
        """Alias for purge_state."""
        return self.purge_state()

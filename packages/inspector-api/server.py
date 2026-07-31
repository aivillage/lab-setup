#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8080"))
REPORTS_DIR = Path(os.environ.get("REPORTS_DIR", "./reports"))
try:
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
except Exception:
    pass

class InspectorHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")

    def _send_json(self, status_code, data):
        body = json.dumps(data, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "healthy"})
            return

        if self.path == "/api/reports":
            reports = []
            for filepath in REPORTS_DIR.glob("*.yaml"):
                reports.append({
                    "filename": filepath.name,
                    "size_bytes": filepath.stat().st_size,
                    "modified_at": filepath.stat().st_mtime
                })
            self._send_json(200, {"count": len(reports), "reports": reports})
            return

        if self.path.startswith("/configs/"):
            conf_name = os.path.basename(self.path)
            configs_dir = Path(os.environ.get("CONFIGS_DIR", "/var/lib/tftpboot/configs"))
            conf_path = configs_dir / conf_name
            content = None

            cache_dir = Path("/var/lib/inspector-api")
            if conf_name == "talosconfig" and (cache_dir / "talosconfig").exists():
                content = (cache_dir / "talosconfig").read_bytes()

            if conf_path.exists() and conf_path.is_file():
                content = conf_path.read_bytes()
            elif conf_path.exists() and conf_path.is_dir() and (conf_path / "bin" / "generate-config").exists():
                cache_dir = Path("/var/lib/inspector-api")
                try:
                    cache_dir.mkdir(parents=True, exist_ok=True)
                except Exception:
                    cache_dir = Path(tempfile.gettempdir()) / "inspector-api"
                    cache_dir.mkdir(parents=True, exist_ok=True)

                gen_patches = configs_dir / "generate-patches" / "bin" / "generate-patches"
                if gen_patches.exists():
                    subprocess.run([str(gen_patches), str(cache_dir)], capture_output=True, text=True, cwd=str(cache_dir))

                secrets_file = cache_dir / "secrets.yaml"
                credentials_dir = os.environ.get("CREDENTIALS_DIRECTORY")
                talos_secrets_credential = os.environ.get("TALOS_SECRETS_CREDENTIAL")
                if credentials_dir and talos_secrets_credential:
                    credential_path = Path(credentials_dir) / talos_secrets_credential
                    if credential_path.exists():
                        secrets_file = credential_path
                secrets_arg = [str(secrets_file)] if secrets_file.exists() else []
                gen_bin = conf_path / "bin" / "generate-config"
                if not secrets_arg:
                    print(f"[WARN] no talos secrets bundle found; {gen_bin} will mint fresh, inconsistent cluster secrets")
                res = subprocess.run([str(gen_bin), str(cache_dir)] + secrets_arg, capture_output=True, text=True, cwd=str(cache_dir))

                yaml_file = cache_dir / conf_name
                if yaml_file.exists():
                    content = yaml_file.read_bytes()
                else:
                    print(f"[ERROR] generate-config ran but output {yaml_file} not found: {res.stderr}")
            else:
                gen_patches = configs_dir / "generate-patches" / "bin" / "generate-patches"
                if gen_patches.exists():
                    with tempfile.TemporaryDirectory() as tmpdir:
                        subprocess.run([str(gen_patches), tmpdir], capture_output=True, text=True, cwd=tmpdir)
                        patch_file = Path(tmpdir) / conf_name
                        if patch_file.exists():
                            content = patch_file.read_bytes()

            if content is not None:
                self.send_response(200)
                self.send_header("Content-Type", "text/yaml")
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
                return

        self._send_json(404, {"error": "Not Found"})

    def do_POST(self):
        if self.path.startswith("/api/reports"):
            content_length = int(self.headers.get("Content-Length", 0))
            payload = self.rfile.read(content_length).decode("utf-8", errors="replace")

            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)

            # Extract hostname from query param, X-Hostname header, path, or payload
            hostname = "unknown"
            if "hostname" in query_params:
                hostname = query_params["hostname"][0]
            elif self.headers.get("X-Hostname"):
                hostname = self.headers.get("X-Hostname")
            else:
                match = re.search(r"inspector-report-([a-zA-Z0-9_-]+)", self.path)
                if match:
                    hostname = match.group(1)
                else:
                    host_match = re.search(r"hostname:\s*[\"']?([a-zA-Z0-9_-]+)", payload)
                    if host_match:
                        hostname = host_match.group(1)

            filename = f"inspector-report-{hostname}.yaml"
            filepath = REPORTS_DIR / filename
            filepath.write_text(payload, encoding="utf-8")

            # Check if global WIPE_ALL or per-host wipe file exists
            global_wipe = (REPORTS_DIR / "WIPE_ALL").exists()
            host_wipe = (REPORTS_DIR / f"WIPE_{hostname}").exists()
            should_wipe = global_wipe or host_wipe

            print(f"[RECV] Saved report to {filepath} (hostname={hostname}, wipe={should_wipe})")

            self._send_json(200, {
                "status": "success",
                "filename": filename,
                "hostname": hostname,
                "wipe": should_wipe
            })
            return

        self._send_json(404, {"error": "Not Found"})

def run():
    server_address = ("", PORT)
    httpd = HTTPServer(server_address, InspectorHandler)
    print(f"Inspector API Server running on port {PORT}...")
    print(f"Reports directory: {REPORTS_DIR.resolve()}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer shutting down.")

if __name__ == "__main__":
    run()

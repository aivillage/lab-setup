#!/usr/bin/env python3
import json
import os
import re
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
            if conf_path.exists() and conf_path.is_file():
                content = conf_path.read_bytes()
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

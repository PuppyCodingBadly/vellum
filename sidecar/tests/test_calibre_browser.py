"""Contract tests for the calibre browser shim."""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SIDECAR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIDECAR))

from vellum_sidecar.vendor import calibre_shim  # noqa: E402


class _Handler(BaseHTTPRequestHandler):
    requests = []

    def do_GET(self):
        self._record()

    def do_POST(self):
        self._record()

    def _record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        type(self).requests.append((self.command, body))
        payload = json.dumps({"method": self.command}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def test_browser_preserves_data_as_post_body():
    _Handler.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        calibre_shim.install()
        from calibre import browser

        url = f"http://127.0.0.1:{server.server_port}/api/decrypt?l=token"
        br = browser(user_agent="test")

        with br.open(url, timeout=5) as response:
            assert json.loads(response.read()) == {"method": "GET"}

        # Calibre store plugins POST an empty body to decrypt endpoints; the
        # empty body must still produce a POST, not a GET.
        with br.open(url, timeout=5, data=b"") as response:
            assert json.loads(response.read()) == {"method": "POST"}

        with br.open(url, timeout=5, data=b"payload") as response:
            assert json.loads(response.read()) == {"method": "POST"}

        assert _Handler.requests == [
            ("GET", b""),
            ("POST", b""),
            ("POST", b"payload"),
        ]
    finally:
        server.shutdown()
        server.server_close()

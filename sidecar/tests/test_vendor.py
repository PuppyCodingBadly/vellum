"""In-process contract tests for the vendored loader/store/bridge fixes."""

import importlib
import sys
import threading
import types
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

SIDECAR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIDECAR))

from vellum_sidecar.bridge import Bridge  # noqa: E402
from vellum_sidecar.vendor import calibre_shim  # noqa: E402
from vellum_sidecar.vendor.archive import _finder  # noqa: E402
from vellum_sidecar.vendor.budget import Budget, DeadlineExceeded, plugin_timeout  # noqa: E402
from vellum_sidecar.vendor.loader import CalibrePluginAdapter  # noqa: E402
from vellum_sidecar.vendor.metadata import (  # noqa: E402
    MAX_COVER_BYTES,
    Metadata,
    fetch_cover_bytes,
)
from vellum_sidecar.vendor.store import (  # noqa: E402
    StoreAdapter,
    StoreDownloadError,
    StoreResult,
)

FAKESRC_INIT = '''
from calibre.ebooks.metadata.sources.base import Source


class FakeSrc(Source):
    name = "Fake Src"
    id = "fakesrc"
    version = (1, 0, 0)
    description = "Fake metadata source for unload tests."
'''


def _build_fakesrc_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("plugin-import-name-fakesrc.txt", "fakesrc")
        zf.writestr("fakesrc/__init__.py", FAKESRC_INIT)


def test_fetch_download_fallback_takes_first_non_empty():
    calibre_shim.install()
    mod = types.ModuleType("fake_store_mod")

    def resolve_spa_download(sr, timeout):
        sr.downloads = {"MOBI": "", "EPUB": "http://x/book.epub"}
        return True

    mod.resolve_spa_download = resolve_spa_download
    adapter = StoreAdapter("Fake Store", "", [mod])
    # No wanted formats, so the code falls back to the downloads map.
    result = adapter.fetch_download(StoreResult(title="T", formats=""))
    assert result is not None
    assert result.download_url == "http://x/book.epub"
    assert result.formats == "EPUB"


def test_adapter_id_falls_back_to_default():
    class Plugin:
        id = ""
        name = ""

    adapter = CalibrePluginAdapter(Plugin())
    assert adapter.id == "calibre-plugin"


def test_translate_empty_isbn_identifier_falls_back_to_isbn_attr():
    class Plugin:
        id = "p"
        name = "P"

    class Result:
        identifiers = {"isbn": ""}
        isbn = "9780306406157"
        title = "T"

    adapter = CalibrePluginAdapter(Plugin())
    meta = adapter._translate(Result())
    assert meta.isbn == "9780306406157"


def test_unload_removes_modules_and_archive(tmp_path):
    calibre_shim.install()
    plugin_dir = tmp_path / "plugins"
    src = tmp_path / "fakesrc.zip"
    _build_fakesrc_zip(src)

    bridge = Bridge()
    resp = bridge._m_load(str(plugin_dir), str(src))
    assert resp["kind"] == "metadata"
    import calibre_plugins.fakesrc  # noqa: F401
    assert "fakesrc" in _finder.archives

    assert bridge._m_unload(str(plugin_dir), resp["name"]) is True
    assert "fakesrc" not in _finder.archives
    assert not any(m == "calibre_plugins.fakesrc"
                   or m.startswith("calibre_plugins.fakesrc.")
                   for m in sys.modules)
    with pytest.raises(ModuleNotFoundError):
        importlib.import_module("calibre_plugins.fakesrc")


def test_unload_unknown_name_returns_false(tmp_path):
    bridge = Bridge()
    assert bridge._m_unload(str(tmp_path / "plugins"), "nope") is False


def test_calibre_prints_writes_to_stderr(capfd):
    calibre_shim.install()
    import calibre
    from calibre.devices.usbms.driver import debug_print

    calibre.prints("plugin chatter")
    debug_print("debug chatter")

    out, err = capfd.readouterr()
    assert out == ""
    assert "plugin chatter" in err
    assert "debug chatter" in err


def test_budget_grants_only_what_is_left():
    budget = Budget(10.0)
    first = plugin_timeout(budget, 5.0)
    assert 0.0 < first <= 10.0
    assert plugin_timeout(budget, 5.0) <= first


def test_expired_budget_raises_and_sets_abort():
    budget = Budget(0)
    with pytest.raises(DeadlineExceeded):
        plugin_timeout(budget, 15.0)
    assert budget.abort.is_set()


def test_budget_without_deadline_keeps_adapter_default():
    assert plugin_timeout(Budget(None), 15.0) == 15.0
    assert plugin_timeout(None, 60.0) == 60.0


def test_resolver_failure_reports_its_reason():
    calibre_shim.install()

    class Store:
        name = "S"

        def get_details(self, result, *args, **kwargs):
            raise RuntimeError("catalog unreadable")

    adapter = StoreAdapter("S", "", [types.ModuleType("m")], plugin=Store())
    with pytest.raises(StoreDownloadError) as excinfo:
        adapter.fetch_download(StoreResult(title="T"))
    assert "catalog unreadable" in str(excinfo.value)


def test_resolver_without_any_strategy_reports_its_reason():
    calibre_shim.install()
    adapter = StoreAdapter("S", "", [types.ModuleType("m")])
    with pytest.raises(StoreDownloadError) as excinfo:
        adapter.fetch_download(StoreResult(title="T"))
    assert "neither" in str(excinfo.value)


JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00" + b"\x00" * 32


class _CoverHandler(BaseHTTPRequestHandler):
    """Serve the shapes a plugin-supplied cover URL can produce."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, status, body, content_type=None):
        self.send_response(status)
        if content_type is not None:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _stream_chunked(self):
        chunk = b"\x00" * 1024
        try:
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for _ in range(64):
                self.wfile.write(b"%x\r\n" % len(chunk))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/cover.jpg":
            self._send(200, JPEG, "image/jpeg")
        elif self.path == "/no-type.jpg":
            self._send(200, JPEG)
        elif self.path == "/page.html":
            self._send(200, b"<html></html>", "text/html")
        elif self.path == "/same-scheme":
            self._redirect("/cover.jpg")
        elif self.path == "/to-file":
            self._redirect("file:///etc/passwd")
        elif self.path == "/stream.jpg":
            self._stream_chunked()
        else:
            self._send(404, b"", "text/plain")


@pytest.fixture
def cover_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _CoverHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()
        server.server_close()


def test_cover_byte_budget_matches_dart_client():
    assert MAX_COVER_BYTES == 10 * 1024 * 1024


def test_cover_fetch_rejects_file_url_without_reading(tmp_path, monkeypatch):
    secret = tmp_path / "id_rsa"
    secret.write_text("PRIVATE KEY")

    def refuse(*_args, **_kwargs):
        pytest.fail("a file:// cover URL was opened")

    monkeypatch.setattr(urllib.request.FileHandler, "file_open", refuse)
    assert fetch_cover_bytes(secret.as_uri(), timeout=2.0) is None


def test_cover_fetch_rejects_redirect_to_file(cover_server, monkeypatch):
    def refuse(*_args, **_kwargs):
        pytest.fail("a redirect to file:// was followed")

    monkeypatch.setattr(urllib.request.FileHandler, "file_open", refuse)
    assert fetch_cover_bytes(f"{cover_server}/to-file", timeout=5.0) is None


def test_cover_fetch_returns_image_bytes(cover_server):
    assert fetch_cover_bytes(f"{cover_server}/cover.jpg", timeout=5.0) == JPEG


def test_cover_fetch_follows_same_scheme_redirect(cover_server):
    assert fetch_cover_bytes(f"{cover_server}/same-scheme", timeout=5.0) == JPEG


def test_cover_fetch_accepts_missing_content_type(cover_server):
    assert fetch_cover_bytes(f"{cover_server}/no-type.jpg", timeout=5.0) == JPEG


def test_cover_fetch_rejects_non_image_content_type(cover_server):
    assert fetch_cover_bytes(f"{cover_server}/page.html", timeout=5.0) is None


def test_cover_fetch_rejects_body_over_byte_cap(cover_server):
    assert fetch_cover_bytes(
        f"{cover_server}/stream.jpg", timeout=5.0, max_bytes=1024
    ) is None


def test_adapter_cover_download_uses_safe_fetch(cover_server, tmp_path):
    class Plugin:
        id = "p"
        name = "P"

    secret = tmp_path / "id_rsa"
    secret.write_text("PRIVATE KEY")
    adapter = CalibrePluginAdapter(Plugin())

    assert adapter.download_cover(
        Metadata(cover_url=f"{cover_server}/cover.jpg")
    ) == JPEG
    assert adapter.download_cover(Metadata(cover_url=secret.as_uri())) is None


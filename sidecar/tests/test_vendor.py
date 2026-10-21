"""In-process contract tests for the vendored loader/store/bridge fixes."""

import importlib
import sys
import types
import zipfile
from pathlib import Path

import pytest

SIDECAR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIDECAR))

from vellum_sidecar.bridge import Bridge  # noqa: E402
from vellum_sidecar.vendor import calibre_shim  # noqa: E402
from vellum_sidecar.vendor.loader import (  # noqa: E402
    CalibrePluginAdapter,
    _finder,
)
from vellum_sidecar.vendor.store import StoreAdapter, StoreResult  # noqa: E402

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
    adapter = StoreAdapter("Fake Store", "", "", [mod])
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

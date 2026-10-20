"""Tests for calibre store-plugin support (core.store + shim stubs)."""

from __future__ import annotations

import shutil
import zipfile
from pathlib import Path

import pytest

from vellum.core.store import (
    StoreResult,
    is_store_plugin,
    load_store_plugin,
)
from vellum.metadata.engine import MetadataEngine
from vellum.plugins.manager import PluginManager

FIXTURES = Path(__file__).parent / "fixtures"
METADATA_ZIP = FIXTURES / "fake-metadata-src.zip"

INIT_PY = '''\
from calibre.customize import StoreBase


class FakeStore(StoreBase):
    name = "Fake Store"
    version = (1, 0, 0)
    description = "A fake store for tests"
    actual_plugin = "calibre_plugins.store_fake.fake_plugin:FakeStorePlugin"
'''

FAKE_PLUGIN_PY = '''\
from PyQt5.Qt import QComboBox, QLabel, QUrl
from calibre.gui2 import open_url
from calibre.gui2.store import StorePlugin
from calibre.gui2.store.basic_config import BasicStoreConfig, BasicStoreConfigWidget
from calibre.gui2.store.search_result import SearchResult
from calibre.gui2.store.web_store_dialog import WebStoreDialog


class FakeStorePlugin(StorePlugin):
    pass


def search_libgen(query, max_results=10, timeout=60, base_url=None):
    results = []
    for i in range(2):
        r = SearchResult()
        r.title = f"Book {i} for {query}"
        r.author = "Test Author"
        r.formats = "EPUB"
        r.detail_item = f"https://example.invalid/book/{i}"
        results.append(r)
    return results


def resolve_spa_download(result, timeout=60):
    result.downloads[result.formats] = "https://example.invalid/book.epub"
    return True
'''


@pytest.fixture()
def store_zip(tmp_path):
    path = tmp_path / "fake-store.zip"
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("plugin-import-name-store_fake.txt", "")
        zf.writestr("__init__.py", INIT_PY)
        zf.writestr("fake_plugin.py", FAKE_PLUGIN_PY)
    return path


def test_is_store_plugin(store_zip):
    assert is_store_plugin(str(store_zip)) is True
    assert is_store_plugin(str(METADATA_ZIP)) is False


def test_load_store_plugin(store_zip):
    adapter = load_store_plugin(str(store_zip))
    assert adapter is not None
    assert adapter.name == "Fake Store"
    assert adapter.description == "A fake store for tests"
    assert adapter.zip_path == str(store_zip)


def test_load_store_plugin_rejects_metadata_zip():
    assert load_store_plugin(str(METADATA_ZIP)) is None


def test_search(store_zip):
    adapter = load_store_plugin(str(store_zip))
    results = adapter.search("x")
    assert len(results) == 2
    for r in results:
        assert isinstance(r, StoreResult)
        assert r.store_name == "Fake Store"
        assert r.author == "Test Author"
        assert r.formats == "EPUB"
    assert results[0].title == "Book 0 for x"
    assert results[0].detail_item == "https://example.invalid/book/0"


def test_fetch_download(store_zip):
    adapter = load_store_plugin(str(store_zip))
    result = adapter.search("x")[0]
    out = adapter.fetch_download(result)
    assert out is not None
    assert out.download_url == "https://example.invalid/book.epub"


def test_manager_skips_store_zips(store_zip, tmp_path):
    plugin_dir = tmp_path / "plugins"
    plugin_dir.mkdir()
    shutil.copy2(store_zip, plugin_dir / store_zip.name)
    shutil.copy2(METADATA_ZIP, plugin_dir / METADATA_ZIP.name)
    manager = PluginManager(MetadataEngine(), str(plugin_dir))
    manager.load_all()
    names = [p["name"] for p in manager.loaded()]
    assert len(names) == 1
    assert "Fake Store" not in names

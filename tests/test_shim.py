"""Tests for the calibre plugin shim, loader, and manager."""

import os

import pytest

from vellum.metadata.engine import MetadataEngine
from vellum.metadata.sources.base import MetadataSource
from vellum.plugins.loader import load_plugin_zip
from vellum.plugins.manager import PluginManager

FIXTURE_ZIP = os.path.join(os.path.dirname(__file__), "fixtures", "fake-metadata-src.zip")


@pytest.fixture
def adapter():
    return load_plugin_zip(FIXTURE_ZIP)


def test_loader_adapter_identity(adapter):
    assert isinstance(adapter, MetadataSource)
    assert adapter.id == "fakesrc"
    assert adapter.name == "Fake Source"


def test_adapter_search_returns_contract_metadata(adapter):
    results = adapter.search(title="x")
    assert len(results) == 2
    titles = {m.title for m in results}
    assert titles == {"Fake Book One", "Fake Book Two"}
    assert {m.isbn for m in results} == {"9780306406157", "9780132350884"}
    for m in results:
        assert m.source_id == "fakesrc"
        assert m.source_name == "Fake Source"


def test_manager_registers_into_engine(tmp_path):
    engine = MetadataEngine()
    manager = PluginManager(engine, str(tmp_path / "plugins"))
    name = manager.load(FIXTURE_ZIP)
    assert name == "Fake Source"

    found = engine.find(title="x")
    assert len(found) == 2
    assert all(m.source_name == "Fake Source" for m in found)


def test_manager_loaded_lists_metadata(tmp_path):
    engine = MetadataEngine()
    manager = PluginManager(engine, str(tmp_path / "plugins"))
    manager.load(FIXTURE_ZIP)
    loaded = manager.loaded()
    assert len(loaded) == 1
    entry = loaded[0]
    assert entry["name"] == "Fake Source"
    assert entry["version"] == "(1, 0, 0)"
    assert "Fake" in entry["description"]


def test_manager_unload_removes_plugin(tmp_path):
    engine = MetadataEngine()
    plugin_dir = tmp_path / "plugins"
    manager = PluginManager(engine, str(plugin_dir))
    manager.load(FIXTURE_ZIP)
    assert manager.loaded()

    manager.unload("Fake Source")
    assert manager.loaded() == []
    assert engine.find(title="x") == []
    assert list(plugin_dir.glob("*.zip")) == []


def test_manager_load_all_isolates_failures(tmp_path):
    plugin_dir = tmp_path / "plugins"
    plugin_dir.mkdir()
    (plugin_dir / "broken.zip").write_bytes(b"not a zip")
    import shutil
    shutil.copy2(FIXTURE_ZIP, plugin_dir / "fake-metadata-src.zip")

    engine = MetadataEngine()
    manager = PluginManager(engine, str(plugin_dir))
    manager.load_all()
    assert [e["name"] for e in manager.loaded()] == ["Fake Source"]

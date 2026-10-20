"""End-to-end tests for the sidecar JSON-lines bridge (subprocess)."""

import json
import os
import subprocess
import sys
import zipfile

import pytest

SIDECAR_MAIN = os.path.join(os.path.dirname(__file__), os.pardir, "main.py")

FAKESRC_INIT = '''
from calibre.ebooks.metadata.sources.base import Source
from calibre.ebooks.metadata.book.base import Metadata as CalibreMetadata


class FakeSource(Source):
    name = "Fake Source"
    id = "fakesrc"
    version = (1, 0, 0)
    description = "Fake calibre metadata source for tests."
    capabilities = frozenset({"identify"})

    def search(self, title="", authors=None, isbn="", timeout=15.0):
        results = []
        for t, i in (("Fake Book One", "9780306406157"),
                     ("Fake Book Two", "9780132350884")):
            m = CalibreMetadata(t, ["Test Author"])
            m.set_identifier("isbn", i)
            m.publisher = "Fake Publisher"
            m.tags = ["fake"]
            results.append(m)
        return results

    def identify(self, log, result_queue, abort, title=None, authors=None,
                 identifiers=None, timeout=30):
        for m in self.search(title=title or ""):
            result_queue.put(m)
'''

STORE_INIT = '''
from calibre.customize import Plugin


class StoreX(Plugin):
    name = "Store X"
    description = "Fake store plugin for tests."
'''

STORE_SEARCH = '''
class _Hit:
    def __init__(self, title, author):
        self.title = title
        self.author = author
        self.formats = "EPUB"
        self.detail_item = "item-1"
        self.cover_url = "http://example.invalid/cover.jpg"


def search_libgen(query, max_results=10, timeout=60.0):
    return [_Hit("Store Hit: " + query, "Store Author")]
'''


def _build_fakesrc_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("plugin-import-name-fakesrc.txt", "fakesrc")
        zf.writestr("fakesrc/__init__.py", FAKESRC_INIT)


def _build_store_zip(path):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("plugin-import-name-store_x.txt", "store_x")
        zf.writestr("store_x/__init__.py", STORE_INIT)
        zf.writestr("store_x/search.py", STORE_SEARCH)


class Sidecar:
    def __init__(self, proc):
        self.proc = proc
        self._next_id = 0

    def call(self, method, **params):
        self._next_id += 1
        req = {"id": self._next_id, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        assert line, f"sidecar closed stdout for {method}"
        resp = json.loads(line)
        assert resp["id"] == self._next_id
        return resp


@pytest.fixture
def sidecar():
    proc = subprocess.Popen(
        [sys.executable, SIDECAR_MAIN],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    yield Sidecar(proc)
    proc.kill()
    proc.wait()


def test_ping(sidecar):
    resp = sidecar.call("ping")
    assert resp.get("result") == "pong"


def test_metadata_plugin_lifecycle(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    zip_path = str(tmp_path / "fake-metadata-src.zip")
    _build_fakesrc_zip(zip_path)

    resp = sidecar.call("load", plugin_dir=plugin_dir, zip_path=zip_path)
    result = resp["result"]
    assert result["kind"] == "metadata"
    assert result["name"] == "Fake Source"
    assert result["version"] == "(1, 0, 0)"
    assert "Fake" in result["description"]

    resp = sidecar.call("metadata_search", title="x", authors=[], isbn="",
                        timeout=15.0)
    results = resp["result"]
    assert len(results) == 2
    assert {m["title"] for m in results} == {"Fake Book One", "Fake Book Two"}
    assert {m["isbn"] for m in results} == {"9780306406157", "9780132350884"}
    for m in results:
        assert m["source_id"] == "fakesrc"
        assert m["source_name"] == "Fake Source"

    resp = sidecar.call("loaded", plugin_dir=plugin_dir)
    names = [e["name"] for e in resp["result"]["metadata"]]
    assert names == ["Fake Source"]

    resp = sidecar.call("unload", plugin_dir=plugin_dir, name="Fake Source")
    assert resp["result"] is True

    resp = sidecar.call("loaded", plugin_dir=plugin_dir)
    assert resp["result"]["metadata"] == []
    assert not any(f.endswith(".zip") for f in os.listdir(plugin_dir))


def test_load_all_isolates_failures(sidecar, tmp_path):
    plugin_dir = tmp_path / "plugins"
    plugin_dir.mkdir()
    (plugin_dir / "broken.zip").write_bytes(b"not a zip")
    _build_fakesrc_zip(str(plugin_dir / "fake-metadata-src.zip"))

    resp = sidecar.call("load_all", plugin_dir=str(plugin_dir))
    result = resp["result"]
    assert [e["name"] for e in result["metadata"]] == ["Fake Source"]
    assert result["stores"] == []


def test_store_plugin(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    zip_path = str(tmp_path / "store-x.zip")
    _build_store_zip(zip_path)

    resp = sidecar.call("load", plugin_dir=plugin_dir, zip_path=zip_path)
    result = resp["result"]
    assert result["kind"] == "store"
    assert result["name"] == "Store X"

    resp = sidecar.call("store_search", store="Store X", query="dune",
                        max_results=10, timeout=30.0)
    results = resp["result"]
    assert len(results) == 1
    hit = results[0]
    assert hit["title"] == "Store Hit: dune"
    assert hit["author"] == "Store Author"
    assert hit["formats"] == "EPUB"
    assert hit["store_name"] == "Store X"


def test_garbage_zip_errors_and_process_survives(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    bad = str(tmp_path / "garbage.zip")
    with open(bad, "wb") as fh:
        fh.write(b"definitely not a zip")

    resp = sidecar.call("load", plugin_dir=plugin_dir, zip_path=bad)
    assert "error" in resp
    assert resp["error"]

    # Process is still alive and responsive.
    resp = sidecar.call("ping")
    assert resp.get("result") == "pong"

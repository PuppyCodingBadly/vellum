"""Protocol-level tests: stdout ownership, concurrent dispatch, error frames."""

import json
import os
import queue
import subprocess
import sys
import threading
import time
import zipfile

import pytest

SIDECAR_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CHATTY_INIT = '''
from calibre import prints
from calibre.devices.usbms.driver import debug_print
from calibre.ebooks.metadata.book.base import Metadata as CalibreMetadata
from calibre.ebooks.metadata.sources.base import Source

prints("import-time chatter")
debug_print("import-time debug chatter")


class ChattySource(Source):
    name = "Chatty Source"
    id = "chatty"
    version = (1, 0, 0)
    description = "Prints while it searches."

    def identify(self, log, result_queue, abort, title=None, authors=None,
                 identifiers=None, timeout=30):
        prints("calibre print during request")
        debug_print("debug print during request")
        print("bare print during request")
        mi = CalibreMetadata("Chatty Book", ["Ann Author"])
        mi.set_identifier("isbn", "9780306406157")
        result_queue.put(mi)
'''

SLEEPY_INIT = '''
import time

from calibre.ebooks.metadata.sources.base import Source


class SleepySource(Source):
    name = "Sleepy Source"
    id = "sleepy"
    version = (1, 0, 0)
    description = "Ignores the timeout it is given."

    def search(self, title="", authors=None, isbn="", timeout=15.0):
        time.sleep(30)
        return []
'''

NAN_INIT = '''
from calibre.ebooks.metadata.book.base import Metadata as CalibreMetadata
from calibre.ebooks.metadata.sources.base import Source


class NanSource(Source):
    name = "NaN Source"
    id = "nan"
    version = (1, 0, 0)
    description = "Returns a rating JSON cannot carry."

    def search(self, title="", authors=None, isbn="", timeout=15.0):
        mi = CalibreMetadata("NaN Book", ["Q"])
        mi.rating = float("nan")
        return [mi]
'''


def _build_zip(path, name, source):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(f"plugin-import-name-{name}.txt", name)
        zf.writestr(f"{name}/__init__.py", source)


class Sidecar:
    """Speaks the protocol, reading frames on a pump thread.

    Every line read must be a complete JSON frame: plugin chatter on stdout
    fails the test instead of being skipped.
    """

    def __init__(self, proc):
        self.proc = proc
        self._next_id = 0
        self._frames: dict = {}
        self._lines: queue.Queue = queue.Queue()
        self._pump = threading.Thread(target=self._read_stdout, daemon=True)
        self._pump.start()

    def _read_stdout(self):
        for line in self.proc.stdout:
            self._lines.put(line)

    def send(self, method, **params):
        self._next_id += 1
        request = {"id": self._next_id, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        return self._next_id

    def call(self, method, **params):
        return self.await_frame(self.send(method, **params))

    def await_frame(self, req_id, timeout=10.0):
        if req_id in self._frames:
            return self._frames.pop(req_id)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"no response for request {req_id}"
            try:
                line = self._lines.get(timeout=remaining)
            except queue.Empty:
                raise AssertionError(f"no response for request {req_id}")
            frame = json.loads(line)  # stdout must carry frames only
            if frame.get("id") == req_id:
                return frame
            self._frames[frame.get("id")] = frame


@pytest.fixture
def sidecar():
    proc = subprocess.Popen(
        [sys.executable, "-m", "vellum_sidecar"],
        cwd=SIDECAR_ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    yield Sidecar(proc)
    proc.kill()
    proc.wait()


def test_stdout_survives_plugin_prints(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    zip_path = str(tmp_path / "chatty.zip")
    _build_zip(zip_path, "chatty", CHATTY_INIT)

    resp = sidecar.call("load", plugin_dir=plugin_dir, zip_path=zip_path)
    assert resp["result"]["kind"] == "metadata"

    # The plugin prints during identify(); the response must still be the
    # next frame on stdout, undamaged.
    resp = sidecar.call("metadata_search", title="x", authors=[], isbn="",
                        timeout=5.0)
    assert [m["title"] for m in resp["result"]] == ["Chatty Book"]
    assert resp["result"][0]["isbn"] == "9780306406157"


def test_sleeping_plugin_does_not_block_ping(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    zip_path = str(tmp_path / "sleepy.zip")
    _build_zip(zip_path, "sleepy", SLEEPY_INIT)
    assert sidecar.call("load", plugin_dir=plugin_dir,
                        zip_path=zip_path)["result"]["name"] == "Sleepy Source"

    slow_id = sidecar.send("metadata_search", title="x", authors=[], isbn="",
                           timeout=0.4)
    time.sleep(0.05)  # let the slow request occupy its worker

    started = time.monotonic()
    pong = sidecar.call("ping")
    elapsed = time.monotonic() - started
    assert pong["result"] == "pong"
    assert elapsed < 2.0

    slow = sidecar.await_frame(slow_id, timeout=5.0)
    assert "result" not in slow
    assert "deadline" in slow["error"]


def test_nan_result_becomes_error_frame(sidecar, tmp_path):
    plugin_dir = str(tmp_path / "plugins")
    zip_path = str(tmp_path / "nan.zip")
    _build_zip(zip_path, "nan", NAN_INIT)
    assert sidecar.call("load", plugin_dir=plugin_dir,
                        zip_path=zip_path)["result"]["name"] == "NaN Source"

    resp = sidecar.call("metadata_search", title="x", authors=[], isbn="",
                        timeout=5.0)
    assert "result" not in resp
    assert "error" in resp

    # The loop survived the unserializable result.
    assert sidecar.call("ping")["result"] == "pong"

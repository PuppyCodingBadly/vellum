"""The sidecar's JSON-lines protocol: one process's stdin to stdout.

The protocol owns the process's real stdout.  Plugin diagnostics
(``calibre.prints``, ``debug_print``, a bare ``print``) go to stderr, so no
plugin can corrupt or drop a response frame.

Each request is dispatched on its own daemon thread, so a stalled plugin
call never delays a later request.  A request gets one monotonic deadline;
when it expires, a watchdog sets the request's abort flag, answers with a
structured error and leaves the worker to unwind on its own.
"""

from __future__ import annotations

import json
import logging
import sys
import threading
from typing import Any, TextIO

from .bridge import Bridge
from .vendor.budget import DeadlineExceeded

log = logging.getLogger(__name__)


def adopt_stdout() -> TextIO:
    """Return the real stdout and point ``sys.stdout`` at stderr.

    Called before any plugin is imported: from here on the returned stream
    is the only writer of protocol frames.
    """
    out = sys.stdout
    sys.stdout = sys.stderr
    return out


class _Writer:
    """Serializes response frames written by worker and watchdog threads."""

    def __init__(self, out: TextIO):
        self._out = out
        self._lock = threading.Lock()

    def reply(self, req_id: Any, body: dict) -> None:
        line = self._encode(req_id, body)
        with self._lock:
            self._out.write(line + "\n")
            self._out.flush()

    @staticmethod
    def _encode(req_id: Any, body: dict) -> str:
        """Encode one frame; anything JSON cannot carry becomes an error frame.

        ``allow_nan=False`` matters: a plugin returning NaN must fail its
        own request rather than emit an invalid frame and kill the loop.
        """
        try:
            return json.dumps({"id": req_id, **body}, allow_nan=False)
        except (TypeError, ValueError) as exc:
            return json.dumps(
                {"id": req_id, "error": f"unserializable response: {exc}"})


class _Request:
    """One in-flight request: its budget, its worker and its watchdog."""

    def __init__(self, bridge: Bridge, writer: _Writer, req_id: Any,
                 method: str, params: dict):
        self.bridge = bridge
        self.writer = writer
        self.req_id = req_id
        self.method = method
        self.params = params
        self.budget = bridge.request_budget(method, params)
        self._lock = threading.Lock()
        self._answered = False

    def start(self) -> None:
        remaining = self.budget.remaining()
        if remaining is not None:
            watchdog = threading.Timer(remaining, self._expire)
            watchdog.daemon = True
            watchdog.start()
        threading.Thread(target=self._dispatch, daemon=True,
                         name=f"request-{self.req_id}").start()

    def _dispatch(self) -> None:
        try:
            result = self.bridge.dispatch(self.method, self.params, self.budget)
        except DeadlineExceeded as exc:
            self.reply({"error": str(exc)})
        except Exception as exc:
            log.exception("request %r (%s) failed", self.req_id, self.method)
            self.reply({"error": str(exc)})
        else:
            self.reply({"result": result})

    def _expire(self) -> None:
        self.budget.abort.set()
        self.reply({"error": f"{self.method} exceeded its "
                             f"{self.budget.timeout}s deadline"})

    def reply(self, body: dict) -> None:
        """Answer once: the watchdog and the worker race here."""
        with self._lock:
            if self._answered:
                return
            self._answered = True
        self.writer.reply(self.req_id, body)


def serve(bridge: Bridge, instream: TextIO, out: TextIO) -> None:
    """Read requests from ``instream`` until it closes, answering on ``out``.

    A malformed line can never stop the loop: it is answered with a
    structured error for its id (unknown when the line is not JSON at all).
    """
    writer = _Writer(out)
    for line in instream:
        line = line.strip()
        if not line:
            continue
        req_id = None
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be a JSON object")
            req_id = request.get("id")
            _Request(bridge, writer, req_id, request.get("method", ""),
                     request.get("params") or {}).start()
        except Exception as exc:
            log.debug("invalid request: %s", exc)
            writer.reply(req_id, {"error": f"invalid request: {exc}"})

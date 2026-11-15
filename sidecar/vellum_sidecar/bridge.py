"""JSON-lines bridge over the vendored vellum plugin machinery.

Requests  : {"id": N, "method": str, "params": {...}}
Responses : {"id": N, "result": ...} or {"id": N, "error": str}

One in-process registry of loaded plugins per plugin_dir.  Requests arrive
on worker threads, so every registry access is locked and every plugin call
of one request draws from the request's shared Budget instead of a fresh
timeout.
"""

from __future__ import annotations

import base64
import dataclasses
import inspect
import logging
import os
import shutil
import tempfile
import threading
from typing import Any

from .vendor.archive import unload_import
from .vendor.budget import Budget, DeadlineExceeded
from .vendor.discovery import LoadedPlugin, load_plugin
from .vendor.metadata import Metadata
from .vendor.store import StoreDownloadError, StoreResult

log = logging.getLogger(__name__)


class _Registry:
    """The plugins loaded for one plugin_dir, plus the last load_all failures.

    ``lock`` guards every field below; it is an RLock because a load
    registers plugins while the bridge already holds it.
    """

    def __init__(self, plugin_dir: str):
        self.plugin_dir = plugin_dir
        os.makedirs(plugin_dir, exist_ok=True)
        self.lock = threading.RLock()
        self.plugins: dict[str, LoadedPlugin] = {}  # plugin name -> loaded
        self.failures: list[dict] = []
        self.load_all_done = False

    def put(self, plugin: LoadedPlugin) -> None:
        with self.lock:
            self.plugins[plugin.adapter.name] = plugin

    def of_kind(self, kind: str) -> list[LoadedPlugin]:
        with self.lock:
            return [p for p in self.plugins.values() if p.kind == kind]


class Bridge:
    """Dispatch bridge requests against per-plugin_dir registries."""

    #: Deadline (seconds) for requests that call plugin code and omit
    #: ``timeout``; the JSON API documents the same defaults.
    _DEFAULT_TIMEOUTS = {
        "metadata_search": 15.0,
        "download_cover": 15.0,
        "store_search": 60.0,
        "store_fetch_download": 60.0,
    }

    def __init__(self):
        self._dirs: dict[str, _Registry] = {}
        self._lock = threading.Lock()

    # -- dispatch -----------------------------------------------------------

    def request_budget(self, method: str, params: dict | None) -> Budget:
        """One deadline and abort flag shared by every call of a request."""
        timeout = (params or {}).get("timeout")
        if timeout is None:
            timeout = self._DEFAULT_TIMEOUTS.get(method)
        return Budget(timeout)

    def dispatch(self, method: str, params: dict | None = None,
                 budget: Budget | None = None) -> Any:
        handler = getattr(self, "_m_" + method, None)
        if handler is None:
            raise ValueError(f"unknown method: {method}")
        args = dict(params or {})
        if budget is None:
            budget = self.request_budget(method, args)
        args.pop("timeout", None)
        if "budget" in inspect.signature(handler).parameters:
            args["budget"] = budget
        return handler(**args)

    # -- registry helpers ---------------------------------------------------

    def _registry(self, plugin_dir: str) -> _Registry:
        key = os.path.abspath(plugin_dir)
        with self._lock:
            reg = self._dirs.get(key)
            if reg is None:
                reg = _Registry(key)
                self._dirs[key] = reg
        return reg

    def _all_registries(self) -> list[_Registry]:
        with self._lock:
            return list(self._dirs.values())

    def _metadata_plugins(self) -> list[LoadedPlugin]:
        plugins: list[LoadedPlugin] = []
        for reg in self._all_registries():
            plugins.extend(reg.of_kind("metadata"))
        return plugins

    def _store_adapter(self, store: str):
        for reg in self._all_registries():
            with reg.lock:
                plugin = reg.plugins.get(store)
            if plugin is not None and plugin.kind == "store":
                return plugin.adapter
        raise ValueError(f"unknown store: {store}")

    def _payload(self, reg: _Registry) -> dict:
        """The ``load_all``/``loaded`` response: both kinds plus failures."""
        with reg.lock:
            return {
                "metadata": [p.entry() for p in reg.plugins.values()
                             if p.kind == "metadata"],
                "stores": [p.entry() for p in reg.plugins.values()
                           if p.kind == "store"],
                "failures": list(reg.failures),
            }

    def _load_all_into(self, reg: _Registry) -> None:
        """Mirror PluginManager.load_all: isolate failures per zip.

        Classification and loading happen inside each entry's try, so one
        unreadable ``*.zip`` (a directory, a truncated download) is
        recorded and skipped instead of aborting the whole scan.
        """
        with reg.lock:
            try:
                entries = sorted(os.listdir(reg.plugin_dir))
            except OSError as exc:
                reg.failures.append({"zip": reg.plugin_dir, "reason": str(exc)})
                entries = []
            for entry in entries:
                if not entry.endswith(".zip"):
                    continue
                path = os.path.join(reg.plugin_dir, entry)
                try:
                    reg.put(load_plugin(path))
                except Exception as exc:
                    reg.failures.append({"zip": path, "reason": str(exc)})
                    log.warning("skipping plugin %s: %s", path, exc)
            reg.load_all_done = True

    # -- methods ------------------------------------------------------------

    def _m_ping(self) -> str:
        return "pong"

    def _m_load_all(self, plugin_dir: str) -> dict:
        reg = self._registry(plugin_dir)
        with reg.lock:
            if not reg.load_all_done:
                self._load_all_into(reg)
        return self._payload(reg)

    def _m_load(self, plugin_dir: str, zip_path: str) -> dict:
        reg = self._registry(plugin_dir)
        with reg.lock:
            plugin = self._install(reg, zip_path)
            reg.put(plugin)
        return plugin.entry()

    def _install(self, reg: _Registry, zip_path: str) -> LoadedPlugin:
        """Install a zip into plugin_dir, validating it before it lands.

        A private copy is loaded first; only a plugin that loaded is
        renamed into place, so a failed install cannot destroy the working
        archive it would have replaced.
        """
        dest = os.path.join(reg.plugin_dir, os.path.basename(zip_path))
        if os.path.abspath(zip_path) == os.path.abspath(dest):
            return load_plugin(dest)
        fd, staged = tempfile.mkstemp(prefix=".install-", suffix=".zip",
                                      dir=reg.plugin_dir)
        os.close(fd)
        plugin = None
        try:
            shutil.copy2(zip_path, staged)
            plugin = load_plugin(staged)
            os.replace(staged, dest)
        except BaseException:
            if plugin is not None:
                unload_import(plugin.import_name)
            _remove(staged)
            raise
        plugin.relocate(dest)
        return plugin

    def _m_unload(self, plugin_dir: str, name: str) -> bool:
        reg = self._registry(plugin_dir)
        with reg.lock:
            plugin = reg.plugins.pop(name, None)
        if plugin is None:
            return False
        unload_import(plugin.import_name)
        _remove(plugin.zip_path)
        return True

    def _m_loaded(self, plugin_dir: str) -> dict:
        reg = self._registry(plugin_dir)
        with reg.lock:
            if not reg.load_all_done:
                self._load_all_into(reg)
        return self._payload(reg)

    def _m_metadata_search(self, budget: Budget, title: str = "",
                           authors: list | None = None,
                           isbn: str = "") -> list[dict]:
        results: list[dict] = []
        failures: list[str] = []
        for plugin in self._metadata_plugins():
            adapter = plugin.adapter
            try:
                found = adapter.search(title=title, authors=authors,
                                       isbn=isbn, budget=budget)
            except DeadlineExceeded:
                raise
            except Exception as exc:
                log.exception("metadata search failed for %r",
                              getattr(adapter, "id", "?"))
                failures.append(f"{adapter.name}: {exc}")
                continue
            results.extend(dataclasses.asdict(m) for m in found)
        if failures and not results:
            # The list-shaped protocol has no room for per-plugin failures
            # beside results, so a search that produced nothing but errors
            # fails the request; partial failures still reach stderr.
            raise RuntimeError("metadata search failed: " + "; ".join(failures))
        if failures:
            log.warning("metadata search incomplete: %s", "; ".join(failures))
        return results

    def _m_download_cover(self, budget: Budget, meta: dict) -> dict:
        fields = {f.name for f in dataclasses.fields(Metadata)}
        md = Metadata(**{k: v for k, v in (meta or {}).items() if k in fields})
        adapter = None
        for plugin in self._metadata_plugins():
            if plugin.adapter.id == md.source_id or plugin.adapter.name == md.source_name:
                adapter = plugin.adapter
                break
        if adapter is None:
            return {"data": None}
        try:
            data = adapter.download_cover(md, budget=budget)
        except DeadlineExceeded:
            raise
        except Exception:
            log.exception("download_cover failed")
            data = None
        if not data:
            return {"data": None}
        return {"data": base64.b64encode(bytes(data)).decode("ascii")}

    def _m_store_search(self, budget: Budget, store: str, query: str,
                        max_results: int = 10) -> list[dict]:
        adapter = self._store_adapter(store)
        return [dataclasses.asdict(r) for r in
                adapter.search(query, max_results=max_results, budget=budget)]

    def _m_store_fetch_download(self, budget: Budget, store: str,
                                result: dict) -> dict:
        adapter = self._store_adapter(store)
        fields = {f.name for f in dataclasses.fields(StoreResult)}
        sr = StoreResult(**{k: v for k, v in (result or {}).items()
                            if k in fields})
        try:
            updated = adapter.fetch_download(sr, budget=budget)
        except StoreDownloadError as exc:
            return {"error": str(exc)}
        return dataclasses.asdict(updated)


def _remove(path: str) -> None:
    """Delete a staging/plugin file, tolerating an already-gone one."""
    try:
        os.remove(path)
    except OSError:
        pass

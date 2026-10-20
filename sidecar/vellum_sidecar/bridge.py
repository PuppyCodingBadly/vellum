"""JSON-lines stdio bridge over the vendored vellum plugin machinery.

Requests  : {"id": N, "method": str, "params": {...}}
Responses : {"id": N, "result": ...} or {"id": N, "error": str}

One in-process registry of metadata adapters and store adapters, keyed per
plugin_dir.  Semantics mirror vellum.plugins.manager.PluginManager and
vellum.core.store exactly.
"""

from __future__ import annotations

import base64
import dataclasses
import logging
import os
import shutil
from typing import Any

from .vendor import store as store_mod
from .vendor.loader import load_plugin_zip
from .vendor.metadata import Metadata
from .vendor.store import StoreResult, is_store_plugin, load_store_plugin

log = logging.getLogger(__name__)


class _Registry:
    """Loaded plugins for a single plugin_dir."""

    def __init__(self, plugin_dir: str):
        self.plugin_dir = plugin_dir
        os.makedirs(plugin_dir, exist_ok=True)
        self.metadata: dict[str, Any] = {}   # name -> CalibrePluginAdapter
        self.zip_paths: dict[str, str] = {}  # metadata name -> zip path
        self.stores: dict[str, Any] = {}     # store name -> StoreAdapter
        self.load_all_done = False


class Bridge:
    """Dispatch bridge requests against per-plugin_dir registries."""

    def __init__(self):
        self._dirs: dict[str, _Registry] = {}

    # -- dispatch -----------------------------------------------------------

    def dispatch(self, method: str, params: dict) -> Any:
        handler = getattr(self, "_m_" + method, None)
        if handler is None:
            raise ValueError(f"unknown method: {method}")
        return handler(**(params or {}))

    # -- helpers ------------------------------------------------------------

    def _registry(self, plugin_dir: str) -> _Registry:
        key = os.path.abspath(plugin_dir)
        reg = self._dirs.get(key)
        if reg is None:
            reg = _Registry(key)
            self._dirs[key] = reg
        return reg

    def _metadata_entries(self, reg: _Registry) -> list[dict]:
        return [
            {
                "name": a.name,
                "version": str(getattr(a, "version", "")),
                "description": str(getattr(a, "description", "")),
            }
            for a in reg.metadata.values()
        ]

    def _store_entries(self, reg: _Registry) -> list[dict]:
        return [
            {"name": s.name, "description": str(getattr(s, "description", ""))}
            for s in reg.stores.values()
        ]

    def _all_registries(self) -> list[_Registry]:
        return list(self._dirs.values())

    def _load_all_into(self, reg: _Registry):
        """Mirror PluginManager.load_all: skip stores, isolate failures."""
        for entry in sorted(os.listdir(reg.plugin_dir)):
            if not entry.endswith(".zip"):
                continue
            path = os.path.join(reg.plugin_dir, entry)
            if is_store_plugin(path):
                try:
                    adapter = load_store_plugin(path)
                    if adapter is not None:
                        reg.stores[adapter.name] = adapter
                except Exception:
                    log.exception("failed to load store plugin %s", path)
                continue
            try:
                adapter = load_plugin_zip(path)
                reg.metadata[adapter.name] = adapter
                reg.zip_paths[adapter.name] = path
            except ValueError as exc:
                log.warning("skipping plugin %s: %s", path, exc)
            except Exception:
                log.exception("failed to load plugin %s", path)
        reg.load_all_done = True

    # -- methods --------------------------------------------------------------

    def _m_ping(self) -> str:
        return "pong"

    def _m_load_all(self, plugin_dir: str) -> dict:
        reg = self._registry(plugin_dir)
        if not reg.load_all_done:
            self._load_all_into(reg)
        return {
            "metadata": self._metadata_entries(reg),
            "stores": self._store_entries(reg),
        }

    def _m_load(self, plugin_dir: str, zip_path: str) -> dict:
        reg = self._registry(plugin_dir)
        dest = os.path.join(reg.plugin_dir, os.path.basename(zip_path))
        if os.path.abspath(zip_path) != os.path.abspath(dest):
            shutil.copy2(zip_path, dest)
        if is_store_plugin(dest):
            adapter = load_store_plugin(dest)
            if adapter is None:
                raise ValueError(f"{zip_path} is not a loadable store plugin")
            reg.stores[adapter.name] = adapter
            return {
                "kind": "store",
                "name": adapter.name,
                "version": "",
                "description": str(getattr(adapter, "description", "")),
            }
        adapter = load_plugin_zip(dest)
        reg.metadata[adapter.name] = adapter
        reg.zip_paths[adapter.name] = dest
        return {
            "kind": "metadata",
            "name": adapter.name,
            "version": str(getattr(adapter, "version", "")),
            "description": str(getattr(adapter, "description", "")),
        }

    def _m_unload(self, plugin_dir: str, name: str) -> bool:
        reg = self._registry(plugin_dir)
        adapter = reg.metadata.pop(name, None)
        zip_path = reg.zip_paths.pop(name, None)
        if zip_path and os.path.exists(zip_path):
            os.remove(zip_path)
        return adapter is not None or zip_path is not None or True

    def _m_loaded(self, plugin_dir: str) -> dict:
        reg = self._registry(plugin_dir)
        if not reg.load_all_done:
            self._load_all_into(reg)
        return {
            "metadata": self._metadata_entries(reg),
            "stores": self._store_entries(reg),
        }

    def _m_metadata_search(self, title: str = "", authors: list | None = None,
                           isbn: str = "", timeout: float = 15.0) -> list[dict]:
        out: list[dict] = []
        for reg in self._all_registries():
            for adapter in reg.metadata.values():
                try:
                    for m in adapter.search(title=title, authors=authors,
                                            isbn=isbn, timeout=timeout):
                        out.append(dataclasses.asdict(m))
                except Exception:
                    log.exception("metadata search failed for %r",
                                  getattr(adapter, "id", "?"))
        return out

    def _m_download_cover(self, meta: dict, timeout: float = 15.0) -> dict:
        fields = {f.name for f in dataclasses.fields(Metadata)}
        md = Metadata(**{k: v for k, v in (meta or {}).items() if k in fields})
        adapter = None
        for reg in self._all_registries():
            for a in reg.metadata.values():
                if a.id == md.source_id or a.name == md.source_name:
                    adapter = a
                    break
            if adapter is not None:
                break
        if adapter is None:
            return {"data": None}
        try:
            data = adapter.download_cover(md, timeout=timeout)
        except Exception:
            log.exception("download_cover failed")
            data = None
        if not data:
            return {"data": None}
        return {"data": base64.b64encode(bytes(data)).decode("ascii")}

    def _m_store_search(self, store: str, query: str,
                        max_results: int = 10,
                        timeout: float = 60.0) -> list[dict]:
        for reg in self._all_registries():
            adapter = reg.stores.get(store)
            if adapter is not None:
                return [dataclasses.asdict(r)
                        for r in adapter.search(query, max_results=max_results,
                                                timeout=timeout)]
        raise ValueError(f"unknown store: {store}")

    def _m_store_fetch_download(self, store: str, result: dict,
                                timeout: float = 60.0) -> dict | None:
        for reg in self._all_registries():
            adapter = reg.stores.get(store)
            if adapter is None:
                continue
            fields = {f.name for f in dataclasses.fields(StoreResult)}
            sr = StoreResult(**{k: v for k, v in (result or {}).items()
                                if k in fields})
            updated = adapter.fetch_download(sr, timeout=timeout)
            return dataclasses.asdict(updated) if updated is not None else None
        raise ValueError(f"unknown store: {store}")

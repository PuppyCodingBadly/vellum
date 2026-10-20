"""Manage installed metadata-source plugins."""

from __future__ import annotations

import logging
import os
import shutil

from vellum.metadata.engine import MetadataEngine
from vellum.plugins.loader import load_plugin_zip

log = logging.getLogger(__name__)


class PluginManager:
    def __init__(self, engine: MetadataEngine, plugin_dir: str):
        self._engine = engine
        self._plugin_dir = plugin_dir
        os.makedirs(plugin_dir, exist_ok=True)
        self._adapters: dict[str, object] = {}
        self._zip_paths: dict[str, str] = {}

    def load_all(self):
        from vellum.core.store import is_store_plugin

        for entry in sorted(os.listdir(self._plugin_dir)):
            if entry.endswith(".zip"):
                path = os.path.join(self._plugin_dir, entry)
                if is_store_plugin(path):
                    # Store plugins are loaded via core.store, not as
                    # metadata sources.
                    continue
                try:
                    self._load_path(path, copy=False)
                except Exception:
                    log.exception("failed to load plugin %s", path)

    def load(self, zip_path: str) -> str:
        from vellum.core.store import is_store_plugin

        if is_store_plugin(zip_path):
            raise ValueError(f"{zip_path} is a store plugin, not a metadata source")
        return self._load_path(zip_path, copy=True)

    def _load_path(self, zip_path: str, copy: bool) -> str:
        dest = os.path.join(self._plugin_dir, os.path.basename(zip_path))
        if copy and os.path.abspath(zip_path) != os.path.abspath(dest):
            shutil.copy2(zip_path, dest)
        adapter = load_plugin_zip(dest)
        self._engine.register_source(adapter)
        self._adapters[adapter.name] = adapter
        self._zip_paths[adapter.name] = dest
        return adapter.name

    def unload(self, name: str):
        adapter = self._adapters.pop(name, None)
        if adapter is not None:
            sources = getattr(self._engine, "_sources", None)
            if isinstance(sources, list) and adapter in sources:
                sources.remove(adapter)
        zip_path = self._zip_paths.pop(name, None)
        if zip_path and os.path.exists(zip_path):
            os.remove(zip_path)

    def loaded(self) -> list[dict]:
        return [
            {
                "name": a.name,
                "version": getattr(a, "version", ""),
                "description": getattr(a, "description", ""),
            }
            for a in self._adapters.values()
        ]

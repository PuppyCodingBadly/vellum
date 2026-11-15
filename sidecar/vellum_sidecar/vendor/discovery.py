"""Load one calibre plugin zip and adapt it to the contract it implements.

The zip's contents decide the kind: a class deriving from calibre's store
plugin bases is a store plugin, a class deriving from ``Source`` is a
metadata source.  The marker file name is only a fallback, because zip
archives in the wild disagree with their own markers.  Keeping the decision
here means the bridge never has to know how a plugin is recognised.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .archive import LoadedArchive, load_archive, unload_import
from .loader import CalibrePluginAdapter, find_source_plugin
from .store import adapt_store_plugin


@dataclass
class LoadedPlugin:
    """One plugin zip, imported and adapted: what the registry stores."""

    kind: str     # "metadata" | "store"
    adapter: Any  # CalibrePluginAdapter | StoreAdapter
    archive: LoadedArchive

    @property
    def import_name(self) -> str:
        return self.archive.import_name

    @property
    def zip_path(self) -> str:
        return self.archive.zip_path

    def entry(self) -> dict:
        """The ``load``/``load_all`` payload for this plugin."""
        return {
            "kind": self.kind,
            "name": self.adapter.name,
            "version": str(getattr(self.adapter, "version", "")),
            "description": str(getattr(self.adapter, "description", "")),
        }

    def relocate(self, zip_path: str) -> None:
        """Re-point the archive after it was atomically installed."""
        self.archive.relocate(zip_path)


def load_plugin(zip_path: str) -> LoadedPlugin:
    """Import and adapt one plugin zip; raises when it is not a usable plugin."""
    loaded = load_archive(zip_path)
    try:
        kind = classify(loaded)
        if kind == "store":
            adapter = adapt_store_plugin(loaded)
        else:
            adapter = CalibrePluginAdapter(find_source_plugin(loaded))
    except BaseException:
        # A half-loaded plugin must not stay importable or registered.
        unload_import(loaded.import_name)
        raise
    return LoadedPlugin(kind, adapter, loaded)


def classify(loaded: LoadedArchive) -> str:
    """Decide the plugin kind from the classes it defines."""
    from calibre.customize import StoreBase
    from calibre.ebooks.metadata.sources.base import Source
    from calibre.gui2.store import StorePlugin

    classes = loaded.classes()
    if any(issubclass(cls, (StorePlugin, StoreBase)) for cls in classes):
        return "store"
    if any(issubclass(cls, Source) for cls in classes):
        return "metadata"
    # Neither base is present (a module-level search function, an old
    # archive): the marker name is the only signal left.
    return "store" if loaded.import_name.startswith("store_") else "metadata"

"""Load calibre metadata-source plugin zips via the calibre shim."""

from __future__ import annotations

import logging
import queue
import sys
import threading
import types
import zipfile

from vellum.metadata.sources.base import Metadata, MetadataSource
from vellum.plugins import calibre_shim

log = logging.getLogger(__name__)


class CalibrePluginAdapter(MetadataSource):
    """Adapt a wrapped calibre metadata-source plugin to MetadataSource."""

    def __init__(self, plugin):
        self._plugin = plugin
        self.id = str(getattr(plugin, "id", "") or getattr(plugin, "name", "calibre-plugin"))
        self.name = str(getattr(plugin, "name", self.id))
        self.version = str(getattr(plugin, "version", ""))
        self.description = str(getattr(plugin, "description", ""))

    # -- MetadataSource contract -------------------------------------------

    def search(self, title: str = "", authors: list[str] | None = None,
               isbn: str = "", timeout: float = 15.0) -> list[Metadata]:
        plugin = self._plugin

        # Pragmatic path: plugin exposes a direct search callable.
        search_fn = getattr(plugin, "search", None)
        if callable(search_fn):
            raw = search_fn(title=title, authors=authors, isbn=isbn, timeout=timeout)
            return [self._translate(m) for m in (raw or [])]

        # Calibre path: drive identify() through a result queue.
        identify = getattr(plugin, "identify", None)
        if callable(identify):
            results: queue.Queue = queue.Queue()
            abort = threading.Event()
            identifiers = {"isbn": isbn} if isbn else {}
            try:
                identify(log, results, abort, title=title or None,
                         authors=authors, identifiers=identifiers,
                         timeout=timeout)
            except Exception:
                log.exception("calibre plugin %r identify() failed", self.id)
            out = []
            while True:
                try:
                    out.append(self._translate(results.get_nowait()))
                except queue.Empty:
                    break
            return out

        return []

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        plugin = self._plugin
        fetch = getattr(plugin, "fetch_cover", None) or getattr(plugin, "download_cover", None)
        if not callable(fetch):
            if meta.cover_url:
                try:
                    import urllib.request
                    with urllib.request.urlopen(meta.cover_url, timeout=timeout) as resp:
                        return resp.read()
                except Exception:
                    log.exception("cover download failed for %r", meta.cover_url)
            return None
        results: queue.Queue = queue.Queue()
        abort = threading.Event()
        try:
            fetch(log, results, abort, title=meta.title or None,
                  authors=meta.authors or None,
                  identifiers={"isbn": meta.isbn} if meta.isbn else {},
                  timeout=timeout)
        except TypeError:
            # Some plugins define a simpler signature.
            try:
                data = fetch(meta)
                return bytes(data) if data else None
            except Exception:
                log.exception("calibre plugin %r download_cover() failed", self.id)
                return None
        except Exception:
            log.exception("calibre plugin %r download_cover() failed", self.id)
            return None
        try:
            item = results.get_nowait()
        except queue.Empty:
            return None
        if isinstance(item, (bytes, bytearray)):
            return bytes(item)
        if isinstance(item, tuple) and item and isinstance(item[-1], (bytes, bytearray)):
            return bytes(item[-1])
        return None

    # -- translation ---------------------------------------------------------

    def _translate(self, m) -> Metadata:
        if isinstance(m, Metadata):
            if not m.source_id:
                m.source_id = self.id
            if not m.source_name:
                m.source_name = self.name
            return m
        identifiers = getattr(m, "identifiers", None) or {}
        rating = getattr(m, "rating", None) or 0.0
        pubdate = getattr(m, "pubdate", None)
        languages = getattr(m, "languages", None) or []
        cover = getattr(m, "cached_cover_url", None)
        if callable(cover):
            try:
                cover = cover(False)
            except Exception:
                cover = None
        return Metadata(
            title=str(getattr(m, "title", "") or ""),
            authors=[str(a) for a in (getattr(m, "authors", None) or [])],
            isbn=str(identifiers.get("isbn", getattr(m, "isbn", "") or "")),
            publisher=str(getattr(m, "publisher", "") or ""),
            pubdate=str(pubdate) if pubdate else "",
            language=str(languages[0]) if languages else "",
            description=str(getattr(m, "comments", "") or ""),
            tags=[str(t) for t in (getattr(m, "tags", None) or [])],
            rating=float(rating),
            cover_url=str(cover) if cover else "",
            source_id=self.id,
            source_name=self.name,
        )


def _find_import_name(zf: zipfile.ZipFile) -> str:
    for name in zf.namelist():
        base = name.rsplit("/", 1)[-1]
        if base.startswith("plugin-import-name-") and base.endswith(".txt"):
            return zf.read(name).decode("utf-8").strip()
    raise ValueError("plugin zip has no plugin-import-name-*.txt marker")


def _load_package(zf: zipfile.ZipFile, import_name: str):
    prefix = import_name + "/"
    py_files = sorted(
        n for n in zf.namelist()
        if n.startswith(prefix) and n.endswith(".py")
        and "/" not in n[len(prefix):]  # top-level package files only
    )
    if not py_files:
        raise ValueError(f"no top-level .py files for package {import_name!r}")

    pkg = types.ModuleType(import_name)
    pkg.__path__ = []
    pkg.__package__ = import_name
    sys.modules[import_name] = pkg

    # __init__.py first, then remaining files in sorted order.
    def sort_key(n):
        stem = n[len(prefix):]
        return (stem != "__init__.py", stem)

    modules = []
    for name in sorted(py_files, key=sort_key):
        stem = name[len(prefix):-3]
        if stem == "__init__":
            mod = pkg
        else:
            mod = types.ModuleType(f"{import_name}.{stem}")
            mod.__package__ = import_name
            sys.modules[mod.__name__] = mod
        code = compile(zf.read(name).decode("utf-8"), name, "exec")
        exec(code, mod.__dict__)
        modules.append(mod)
    return pkg, modules


def _find_plugin_instance(pkg, modules):
    from calibre.customize import Plugin
    from calibre.ebooks.metadata.sources.base import Source

    # Prefer the declared entry point: Plugin subclass with load_actual_plugin.
    # Only classes defined by the plugin's own modules qualify; base classes
    # imported from the shim (Source, Plugin) are excluded.
    candidates = []
    for mod in [pkg, *modules]:
        for value in vars(mod).values():
            if (
                isinstance(value, type)
                and issubclass(value, Source)
                and value is not Source
                and value.__module__.startswith(pkg.__name__)
            ):
                candidates.append(value)
    if not candidates:
        raise ValueError("no metadata Source subclass found in plugin")
    cls = candidates[0]
    try:
        return cls.load_actual_plugin(pkg)
    except Exception:
        return cls()


def load_plugin_zip(zip_path: str) -> MetadataSource:
    """Load a calibre plugin zip and return a MetadataSource adapter."""
    calibre_shim.install()
    with zipfile.ZipFile(zip_path) as zf:
        import_name = _find_import_name(zf)
        pkg, modules = _load_package(zf, import_name)
    plugin = _find_plugin_instance(pkg, modules)
    return CalibrePluginAdapter(plugin)

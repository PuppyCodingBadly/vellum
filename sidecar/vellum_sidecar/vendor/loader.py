"""Adapt calibre metadata-source plugin packages to MetadataSource."""

from __future__ import annotations

import queue

from . import calibre_shim
from .archive import LoadedArchive
from .budget import Budget, plugin_abort, plugin_timeout
from .metadata import Metadata, MetadataSource, fetch_cover_bytes

log = calibre_shim.PluginLog(__name__)


class CalibrePluginAdapter(MetadataSource):
    """Adapt a wrapped calibre metadata-source plugin to MetadataSource."""

    def __init__(self, plugin):
        self._plugin = plugin
        self.id = str(getattr(plugin, "id", "") or getattr(plugin, "name", "") or "calibre-plugin")
        self.name = str(getattr(plugin, "name", self.id))
        self.version = str(getattr(plugin, "version", ""))
        self.description = str(getattr(plugin, "description", ""))

    # -- MetadataSource contract -------------------------------------------

    def search(self, title: str = "", authors: list[str] | None = None,
               isbn: str = "", budget: Budget | None = None) -> list[Metadata]:
        plugin = self._plugin
        timeout = plugin_timeout(budget, 15.0)

        # Pragmatic path: plugin exposes a direct search callable.
        search_fn = getattr(plugin, "search", None)
        if callable(search_fn):
            raw = search_fn(title=title, authors=authors, isbn=isbn, timeout=timeout)
            return [self._translate(m) for m in (raw or [])]

        # Calibre path: drive identify() through a result queue.  Errors
        # propagate: the bridge reports which source failed instead of
        # presenting a broken plugin as an empty result page.
        identify = getattr(plugin, "identify", None)
        if callable(identify):
            results: queue.Queue = queue.Queue()
            identifiers = {"isbn": isbn} if isbn else {}
            identify(log, results, plugin_abort(budget), title=title or None,
                     authors=authors, identifiers=identifiers,
                     timeout=timeout)
            out = []
            while True:
                try:
                    out.append(self._translate(results.get_nowait()))
                except queue.Empty:
                    break
            return out

        return []

    def download_cover(self, meta: Metadata,
                       budget: Budget | None = None) -> bytes | None:
        plugin = self._plugin
        timeout = plugin_timeout(budget, 15.0)
        fetch = getattr(plugin, "fetch_cover", None) or getattr(plugin, "download_cover", None)
        if not callable(fetch):
            if meta.cover_url:
                return fetch_cover_bytes(meta.cover_url, timeout)
            return None
        results: queue.Queue = queue.Queue()
        try:
            fetch(log, results, plugin_abort(budget), title=meta.title or None,
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
        cover = (getattr(m, "cached_cover_url", None)
                 or getattr(m, "cover_url", None))
        if callable(cover):
            try:
                cover = cover(False)
            except Exception:
                cover = None
        return Metadata(
            title=str(getattr(m, "title", "") or ""),
            authors=[str(a) for a in (getattr(m, "authors", None) or [])],
            isbn=str(identifiers.get("isbn") or getattr(m, "isbn", "") or ""),
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


def find_source_plugin(loaded: LoadedArchive):
    """Return the calibre metadata Source instance a loaded package defines.

    Only classes the plugin itself defines qualify: base classes imported
    from the shim (``Source``, ``Plugin``) are not plugins.
    """
    from calibre.ebooks.metadata.sources.base import Source

    candidates = [cls for cls in loaded.classes() if issubclass(cls, Source)]
    if not candidates:
        raise ValueError("no metadata Source subclass found in plugin")
    candidates.sort(key=lambda cls: cls.__module__.count("."))
    cls = candidates[0]
    try:
        return cls.load_actual_plugin(loaded.pkg)
    except Exception:
        return cls()

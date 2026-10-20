"""Metadata lookup engine: aggregates results across registered sources."""

from __future__ import annotations

import logging

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)


class MetadataEngine:
    """Queries registered metadata sources and merges results.

    Sources are queried sequentially; parallelizing with threads is a
    planned later optimization.
    """

    def __init__(self) -> None:
        self._sources: list[MetadataSource] = []

    def register_source(self, source: MetadataSource) -> None:
        self._sources.append(source)

    def sources(self) -> list[MetadataSource]:
        return list(self._sources)

    def find(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        results: list[Metadata] = []
        for source in self._sources:
            try:
                results.extend(
                    source.search(title=title, authors=authors, isbn=isbn, timeout=timeout)
                )
            except Exception as exc:
                log.warning("Metadata source %s failed: %s", source.id, exc)
        return self._dedupe(results)

    def fetch_cover(self, meta: Metadata) -> bytes | None:
        for source in self._sources:
            if source.id == meta.source_id:
                try:
                    return source.download_cover(meta)
                except Exception as exc:
                    log.warning("Cover fetch from %s failed: %s", source.id, exc)
                    return None
        return None

    @staticmethod
    def _dedupe(results: list[Metadata]) -> list[Metadata]:
        # Key by ISBN when present, else normalized (title, authors).
        merged: dict = {}
        order: list = []
        for meta in results:
            key = (
                ("isbn", meta.isbn)
                if meta.isbn
                else ("ta", meta.title.lower(), tuple(a.lower() for a in meta.authors))
            )
            existing = merged.get(key)
            if existing is None:
                merged[key] = meta
                order.append(key)
            elif meta.rating > existing.rating:
                merged[key] = meta
        deduped = [merged[key] for key in order]
        deduped.sort(key=lambda m: -m.rating)
        return deduped

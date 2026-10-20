"""Metadata lookup engine: aggregates results across registered sources."""

from __future__ import annotations

import logging
from dataclasses import replace

import requests

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

    def grab_url(self, url: str, timeout: float = 20.0) -> Metadata | None:
        """Extract metadata from an arbitrary book page URL."""
        from vellum.metadata.universal import UniversalGrabber

        return UniversalGrabber().grab(url, timeout=timeout)

    def find_all(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        """Return search results with a merged best match first, if any."""
        results = self.find(title=title, authors=authors, isbn=isbn, timeout=timeout)
        merged = self.merge_results(results)
        if merged is not None and len(results) > 1:
            return [merged] + results
        return results

    @staticmethod
    def merge_results(results: list[Metadata]) -> Metadata | None:
        """Combine fields from every result into one best-effort record."""
        if not results:
            return None
        if len(results) == 1:
            return results[0]

        def completeness(meta: Metadata) -> tuple:
            return (
                sum(
                    bool(value)
                    for value in (
                        meta.title,
                        meta.authors,
                        meta.isbn,
                        meta.publisher,
                        meta.pubdate,
                        meta.language,
                        meta.description,
                        meta.cover_url,
                    )
                ),
                meta.rating,
                len(meta.description),
            )

        best = max(results, key=completeness)
        merged = replace(best)
        merged.source_id = "merged"
        merged.source_name = "Merged sources"

        for field in ("title", "isbn", "publisher", "pubdate", "language"):
            if getattr(merged, field):
                continue
            for meta in results:
                value = getattr(meta, field)
                if value:
                    setattr(merged, field, value)
                    break

        descriptions = [meta.description for meta in results if meta.description]
        if descriptions:
            merged.description = max(descriptions, key=len)

        if not merged.cover_url:
            merged.cover_url = next(
                (meta.cover_url for meta in results if meta.cover_url), ""
            )

        authors: list[str] = []
        tags: list[str] = []
        for meta in results:
            for name in meta.authors:
                if name not in authors:
                    authors.append(name)
            for tag in meta.tags:
                if tag not in tags:
                    tags.append(tag)
        merged.authors = authors
        merged.tags = tags
        merged.rating = max((meta.rating for meta in results), default=0.0)
        return merged

    def fetch_cover(self, meta: Metadata) -> bytes | None:
        for source in self._sources:
            if source.id == meta.source_id or source.name == meta.source_name:
                try:
                    return source.download_cover(meta)
                except Exception as exc:
                    log.warning("Cover fetch from %s failed: %s", source.id, exc)
                    return None
        if not meta.cover_url:
            return None
        try:
            resp = requests.get(
                meta.cover_url,
                timeout=15,
                headers={"User-Agent": "Vellum/0.1 metadata grabber"},
            )
            resp.raise_for_status()
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if content_type and not content_type.startswith("image/"):
                return None
            return resp.content
        except Exception as exc:
            log.warning("Cover fetch from %s failed: %s", meta.cover_url, exc)
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

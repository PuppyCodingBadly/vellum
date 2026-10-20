"""Metadata lookup engine: aggregates results across registered sources."""

from __future__ import annotations

import logging
import re
from dataclasses import replace
from difflib import SequenceMatcher

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

MAX_COVER_BYTES = 10 * 1024 * 1024


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
        return [
            meta for meta in self._dedupe(results) if _is_english(meta)
        ]

    def grab_url(self, url: str, timeout: float = 20.0) -> Metadata | None:
        """Extract metadata from an arbitrary book page URL."""
        from vellum.metadata.universal import UniversalGrabber

        return UniversalGrabber().grab(url, timeout=timeout)

    def find_query(self, query: str, timeout: float = 15.0) -> list[Metadata]:
        """Search metadata sources with a free-form fuzzy query string.

        An ISBN-like string is looked up by ISBN; anything else is treated
        as a fuzzy title/author string and ranked locally by token overlap
        and title similarity after the sources respond.
        """
        query = " ".join((query or "").split())
        if not query:
            return []
        isbn = _query_isbn(query)
        if isbn:
            results = self.find(isbn=isbn, timeout=timeout)
        else:
            results = []
            for source in self._sources:
                try:
                    search_free_text = getattr(
                        source, "search_free_text", None
                    )
                    if search_free_text is not None:
                        results.extend(
                            search_free_text(query, timeout=timeout)
                        )
                    else:
                        results.extend(
                            source.search(title=query, timeout=timeout)
                        )
                except Exception as exc:
                    log.warning(
                        "Metadata source %s failed: %s", source.id, exc
                    )
            results = [
                meta
                for meta in self._dedupe(results)
                if _is_english(meta)
            ]
            results.sort(
                key=lambda meta: (-_fuzzy_score(query, meta), -meta.rating)
            )
        merged = self.merge_results(results)
        if merged is not None and len(results) > 1:
            return [merged] + results
        return results

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
                stream=True,
            )
            resp.raise_for_status()
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if content_type and not content_type.startswith("image/"):
                return None
            chunks: list[bytes] = []
            size = 0
            for chunk in resp.iter_content(64 * 1024):
                if not chunk:
                    continue
                size += len(chunk)
                if size > MAX_COVER_BYTES:
                    return None
                chunks.append(chunk)
            resp.close()
            return b"".join(chunks)
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


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", text.lower())).strip()


def _is_english(meta: Metadata) -> bool:
    language = (meta.language or "").strip().lower()
    if not language:
        return True  # sources often omit it; don't discard the result
    return language.startswith("en") or language in ("english", "eng")


def _query_isbn(query: str) -> str:
    digits = re.sub(r"[^0-9Xx]", "", query)
    if len(digits) == 13 and digits.isdigit():
        return digits
    if len(digits) == 10 and digits[:-1].isdigit() and (
        digits[-1].isdigit() or digits[-1].upper() == "X"
    ):
        return digits.upper()
    return ""


def _fuzzy_score(query: str, meta: Metadata) -> float:
    """Score a result against a free-form query: title, authors, rating."""
    normalized_query = _normalize(query)
    title = _normalize(meta.title)
    authors = _normalize(", ".join(meta.authors))
    if not normalized_query:
        return 0.0

    if normalized_query == title:
        score = 150.0
    elif normalized_query in title:
        score = 100.0
    elif title:
        score = SequenceMatcher(None, normalized_query, title).ratio() * 40.0
        if title in normalized_query:
            score += 40.0
    else:
        score = 0.0

    title_tokens = set(title.split())
    author_tokens = set(authors.split())
    for token in normalized_query.split():
        if token in title_tokens:
            score += 12.0
        if token in author_tokens:
            score += 8.0
        elif token in authors:
            score += 4.0
    score += max(0.0, meta.rating) * 2.0
    if meta.isbn and meta.isbn.lower() in normalized_query:
        score += 100.0
    return score

"""Sorting for metadata search results."""

from __future__ import annotations

from vellum.metadata.sources.base import Metadata

RESULT_SORT_OPTIONS = (
    ("relevance", "Relevance"),
    ("title", "Title"),
    ("author", "Author"),
    ("rating", "Rating"),
    ("pubdate", "Newest"),
)
RESULT_SORT_KEYS = tuple(key for key, _label in RESULT_SORT_OPTIONS)


def _title(meta: Metadata) -> str:
    return (meta.title or "Untitled").casefold()


def _author(meta: Metadata) -> str:
    return (", ".join(meta.authors) or "\uffff").casefold()


def sort_metadata(results: list[Metadata], key: str = "relevance") -> list[Metadata]:
    """Sort search results, keeping a merged best-match row first."""
    items = list(results)
    if key == "relevance" or not items:
        return items

    merged = [meta for meta in items if meta.source_id == "merged"]
    rest = [meta for meta in items if meta.source_id != "merged"]
    if key == "title":
        rest.sort(key=_title)
    elif key == "author":
        rest.sort(key=lambda meta: (_author(meta), _title(meta)))
    elif key == "rating":
        rest.sort(key=lambda meta: (-(meta.rating or 0.0), _title(meta)))
    elif key == "pubdate":
        dated = [meta for meta in rest if meta.pubdate]
        undated = [meta for meta in rest if not meta.pubdate]
        dated.sort(key=lambda meta: meta.pubdate, reverse=True)
        rest = dated + sorted(undated, key=_title)
    return merged + rest

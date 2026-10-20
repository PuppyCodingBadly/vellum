"""Crossref book/work metadata source."""

from __future__ import annotations

import html
import logging
import re

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://api.crossref.org/works"
FIELDS = "DOI,title,author,publisher,published,ISBN,subject,abstract,URL"


class Crossref(MetadataSource):
    id = "crossref"
    name = "Crossref"

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        query = isbn or " ".join(
            part for part in [title, *(authors or [])[:1]] if part
        )
        if not query:
            return []
        return self._query(query, timeout)

    def search_free_text(
        self, query: str, timeout: float = 15.0
    ) -> list[Metadata]:
        query = (query or "").strip()
        if not query:
            return []
        return self._query(query, timeout)

    def _query(self, query: str, timeout: float) -> list[Metadata]:
        try:
            resp = requests.get(
                API_URL,
                params={
                    "query.bibliographic": query,
                    "rows": 20,
                    "select": FIELDS,
                },
                timeout=timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Crossref search failed: %s", exc)
            return []
        items = (data.get("message") or {}).get("items") or []
        return [
            meta for meta in (self._parse_item(item) for item in items) if meta
        ]

    @staticmethod
    def _parse_item(item: dict) -> Metadata | None:
        title = _text(item.get("title"))
        if not title:
            return None
        authors = []
        for author in item.get("author") or []:
            name = " ".join(
                part for part in (author.get("given"), author.get("family"))
                if part
            ).strip()
            if name and name not in authors:
                authors.append(name)
        published = item.get("published") or item.get("issued") or {}
        parts = (published.get("date-parts") or [[]])[0]
        pubdate = "-".join(str(part) for part in parts if part)
        return Metadata(
            title=title,
            authors=authors,
            isbn=_text(item.get("ISBN")),
            publisher=_text(item.get("publisher")),
            pubdate=pubdate,
            description=_clean(_text(item.get("abstract"))),
            tags=_list(item.get("subject"))[:8],
            source_id=_text(item.get("DOI")),
            source_name="Crossref",
        )


def _list(value) -> list[str]:
    values = value if isinstance(value, list) else [value]
    result = []
    for item in values:
        text = _text(item)
        if text and text not in result:
            result.append(text)
    return result


def _text(value) -> str:
    if isinstance(value, list):
        value = value[0] if value else ""
    return re.sub(r"\s+", " ", str(value or "")).strip()


def _clean(value: str) -> str:
    text = re.sub(r"<[^>]+>", " ", value)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()

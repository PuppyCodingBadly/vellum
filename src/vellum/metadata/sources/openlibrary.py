"""Open Library metadata source."""

from __future__ import annotations

import logging

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://openlibrary.org/search.json"
COVER_URL = "https://covers.openlibrary.org/b/id/{}-L.jpg"


class OpenLibrary(MetadataSource):
    id = "openlibrary"
    name = "Open Library"

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        params: dict = {
            "limit": 20,
            "language": "eng",
            # Without an explicit fields list the search API omits ISBNs.
            "fields": (
                "key,title,author_name,first_publish_year,publisher,"
                "language,subject,cover_i,isbn"
            ),
        }
        if title:
            params["title"] = title
        authors = authors or []
        if authors:
            params["author"] = authors[0]
        if isbn:
            params["isbn"] = isbn
        if not (title or authors or isbn):
            return []
        try:
            resp = requests.get(API_URL, params=params, timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Open Library search failed: %s", exc)
            return []
        return [m for m in (self._parse_doc(doc) for doc in data.get("docs", [])) if m]

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        if not meta.cover_url:
            return None
        try:
            resp = requests.get(meta.cover_url, timeout=timeout)
            resp.raise_for_status()
            return resp.content
        except Exception as exc:
            log.warning("Open Library cover download failed: %s", exc)
            return None

    def search_free_text(
        self, query: str, timeout: float = 15.0
    ) -> list[Metadata]:
        query = (query or "").strip()
        if not query:
            return []
        params = {
            "q": query,
            "limit": 20,
            "language": "eng",
            "fields": (
                "key,title,author_name,first_publish_year,publisher,"
                "language,subject,cover_i,isbn"
            ),
        }
        try:
            resp = requests.get(API_URL, params=params, timeout=timeout)
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Open Library free-text search failed: %s", exc)
            return []
        return [
            meta
            for meta in (self._parse_doc(doc) for doc in data.get("docs", []))
            if meta
        ]

    @staticmethod
    def _parse_doc(doc: dict) -> Metadata | None:
        if not doc.get("title"):
            return None
        isbns = doc.get("isbn") or []
        isbn = ""
        for candidate in isbns:
            if len(candidate) == 13:
                isbn = candidate
                break
        if not isbn and isbns:
            isbn = isbns[0]
        cover_id = doc.get("cover_i")
        pubdate = doc.get("first_publish_year")
        return Metadata(
            title=doc.get("title", ""),
            authors=list(doc.get("author_name") or []),
            isbn=isbn,
            publisher=(doc.get("publisher") or [""])[0],
            pubdate=str(pubdate) if pubdate else "",
            language=(doc.get("language") or [""])[0],
            description="",
            tags=list((doc.get("subject") or [])[:8]),
            rating=0.0,
            cover_url=COVER_URL.format(cover_id) if cover_id else "",
            source_id=doc.get("key", ""),
            source_name="Open Library",
        )

"""Google Books metadata source."""

from __future__ import annotations

import logging

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://www.googleapis.com/books/v1/volumes"


class GoogleBooks(MetadataSource):
    id = "google-books"
    name = "Google Books"

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        parts = []
        if title:
            parts.append(f"intitle:{title}")
        for author in authors or []:
            if author:
                parts.append(f"inauthor:{author}")
        if isbn:
            parts.append(f"isbn:{isbn}")
        if not parts:
            return []
        try:
            resp = requests.get(
                API_URL,
                params={"q": "+".join(parts), "maxResults": 20},
                timeout=timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Google Books search failed: %s", exc)
            return []
        return [m for m in (self._parse_item(item) for item in data.get("items", [])) if m]

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        if not meta.cover_url:
            return None
        try:
            resp = requests.get(meta.cover_url, timeout=timeout)
            resp.raise_for_status()
            return resp.content
        except Exception as exc:
            log.warning("Google Books cover download failed: %s", exc)
            return None

    @staticmethod
    def _parse_item(item: dict) -> Metadata | None:
        info = item.get("volumeInfo") or {}
        if not info:
            return None
        isbn = ""
        isbn10 = ""
        for ident in info.get("industryIdentifiers") or []:
            value = ident.get("identifier", "")
            if ident.get("type") == "ISBN_13":
                isbn = value
                break
            if ident.get("type") == "ISBN_10" and not isbn10:
                isbn10 = value
        if not isbn:
            isbn = isbn10
        cover_url = ""
        links = info.get("imageLinks") or {}
        if links.get("thumbnail"):
            # Prefer a higher-resolution image than the default thumbnail.
            cover_url = links["thumbnail"].replace("zoom=1", "zoom=0")
        return Metadata(
            title=info.get("title", ""),
            authors=list(info.get("authors") or []),
            isbn=isbn,
            publisher=info.get("publisher", ""),
            pubdate=info.get("publishedDate", ""),
            language=info.get("language", ""),
            description=info.get("description", ""),
            tags=list(info.get("categories") or []),
            rating=float(info.get("averageRating") or 0.0),
            cover_url=cover_url,
            source_id=item.get("id", ""),
            source_name="Google Books",
        )

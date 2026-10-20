"""Library of Congress book metadata source."""

from __future__ import annotations

import html
import logging
import re

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://www.loc.gov/books/"
MAX_COVER_BYTES = 10 * 1024 * 1024


class LibraryOfCongress(MetadataSource):
    id = "library-of-congress"
    name = "Library of Congress"

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
                    "q": query,
                    "fo": "json",
                    "c": 20,
                    "fa": "language:english",
                },
                timeout=timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Library of Congress search failed: %s", exc)
            return []
        results = data.get("results") or []
        return [
            meta for meta in (self._parse_result(item) for item in results)
            if meta
        ]

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        if not meta.cover_url:
            return None
        try:
            resp = requests.get(meta.cover_url, timeout=timeout, stream=True)
            resp.raise_for_status()
            data = b""
            for chunk in resp.iter_content(64 * 1024):
                data += chunk
                if len(data) > MAX_COVER_BYTES:
                    return None
            return data
        except Exception as exc:
            log.warning("Library of Congress cover download failed: %s", exc)
            return None

    @staticmethod
    def _parse_result(item: dict) -> Metadata | None:
        title = _text(item.get("title"))
        if not title:
            return None
        extras = item.get("item") or {}
        images = item.get("image_url") or extras.get("image_url") or []
        cover = ""
        if images:
            cover = _text(images[0]).split("#", 1)[0]
        publisher = _text(
            extras.get("created_published") or item.get("publisher")
        )
        language = _text(extras.get("language") or item.get("language"))
        isbn = _text(item.get("number_isbn") or item.get("isbn"))
        return Metadata(
            title=title,
            authors=_list(item.get("contributor")),
            isbn=isbn,
            publisher=publisher,
            pubdate=_text(item.get("date")),
            language=language,
            description=_clean(_text(item.get("description"))),
            tags=_list(item.get("subject"))[:8],
            cover_url=cover,
            source_id=f"loc:{_text(item.get('id'))}",
            source_name="Library of Congress",
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

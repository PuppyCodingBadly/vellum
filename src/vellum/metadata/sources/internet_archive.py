"""Internet Archive book metadata source."""

from __future__ import annotations

import html
import logging
import re
from urllib.parse import quote

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://archive.org/advancedsearch.php"
COVER_URL = "https://archive.org/services/img/{identifier}"
FIELDS = (
    "identifier,title,creator,date,publisher,language,description,"
    "subject,isbn"
)
MAX_COVER_BYTES = 10 * 1024 * 1024


class InternetArchive(MetadataSource):
    id = "internet-archive"
    name = "Internet Archive"

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        clauses = []
        if isbn:
            clauses.append(f"isbn:({isbn})")
        if title:
            clauses.append(f"title:({title})")
        for author in (authors or [])[:1]:
            if author:
                clauses.append(f"creator:({author})")
        if not clauses:
            return []
        return self._query(
            " AND ".join(clauses)
            + " AND mediatype:texts AND language:(eng OR English)",
            timeout,
        )

    def search_free_text(
        self, query: str, timeout: float = 15.0
    ) -> list[Metadata]:
        query = (query or "").strip()
        if not query:
            return []
        return self._query(
            f"({query}) AND mediatype:texts AND language:(eng OR English)",
            timeout,
        )

    def _query(self, query: str, timeout: float) -> list[Metadata]:
        try:
            resp = requests.get(
                API_URL,
                params={
                    "q": query,
                    "fl[]": list(FIELDS.split(",")),
                    "rows": 20,
                    "output": "json",
                },
                timeout=timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Internet Archive search failed: %s", exc)
            return []
        docs = (data.get("response") or {}).get("docs") or []
        return [
            meta for meta in (self._parse_doc(doc) for doc in docs) if meta
        ]

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        if not meta.cover_url:
            return None
        try:
            resp = requests.get(meta.cover_url, timeout=timeout, stream=True)
            resp.raise_for_status()
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if content_type and not content_type.startswith("image/"):
                return None
            data = b""
            for chunk in resp.iter_content(64 * 1024):
                data += chunk
                if len(data) > MAX_COVER_BYTES:
                    return None
            return data
        except Exception as exc:
            log.warning("Internet Archive cover download failed: %s", exc)
            return None

    @staticmethod
    def _parse_doc(doc: dict) -> Metadata | None:
        identifier = _text(doc.get("identifier"))
        title = _text(doc.get("title"))
        if not identifier or not title:
            return None
        isbn = _isbn(doc.get("isbn"))
        return Metadata(
            title=title,
            authors=_list(doc.get("creator")),
            isbn=isbn,
            publisher=_text(doc.get("publisher")),
            pubdate=_text(doc.get("date")),
            language=_text(doc.get("language")),
            description=_clean(_text(doc.get("description"))),
            tags=_list(doc.get("subject"))[:8],
            cover_url=COVER_URL.format(identifier=quote(identifier)),
            source_id=f"internet-archive:{identifier}",
            source_name="Internet Archive",
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


def _isbn(value) -> str:
    values = _list(value)
    for candidate in values:
        digits = re.sub(r"[^0-9Xx]", "", candidate)
        if len(digits) == 13 and digits.isdigit():
            return digits
    for candidate in values:
        digits = re.sub(r"[^0-9Xx]", "", candidate)
        if len(digits) == 10:
            return digits.upper()
    return values[0] if values else ""

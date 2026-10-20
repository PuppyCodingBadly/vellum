"""Inventaire (Wikidata-centered) book metadata source."""

from __future__ import annotations

import logging
import re

import requests

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

API_URL = "https://inventaire.io/api/search"
ENTITIES_URL = "https://inventaire.io/api/entities"
BASE_URL = "https://inventaire.io"
MAX_COVER_BYTES = 10 * 1024 * 1024
_BATCH = 40


class Inventaire(MetadataSource):
    id = "inventaire"
    name = "Inventaire"

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        if isbn:
            return self._search(isbn, "editions", timeout)
        query = " ".join(
            part for part in [title, *(authors or [])[:1]] if part
        )
        if not query:
            return []
        return self._search(query, "works", timeout)

    def search_free_text(
        self, query: str, timeout: float = 15.0
    ) -> list[Metadata]:
        query = (query or "").strip()
        if not query:
            return []
        return self._search(query, "works", timeout)

    def _search(
        self, query: str, entity_type: str, timeout: float
    ) -> list[Metadata]:
        try:
            resp = requests.get(
                API_URL,
                params={
                    "search": query,
                    "types": entity_type,
                    "limit": 20,
                },
                timeout=timeout,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            log.warning("Inventaire search failed: %s", exc)
            return []

        results = [
            item for item in (data.get("results") or []) if item.get("uri")
        ]
        entities = self._fetch_entities(
            [item["uri"] for item in results], timeout
        )

        related: set[str] = set()
        for entity in entities.values():
            for prop in ("P50", "P123", "P136", "P407", "P629"):
                related.update(_claims(entity, prop))
        related.difference_update(entities)
        if related:
            entities.update(
                self._fetch_entities(sorted(related), timeout)
            )

        metas = []
        for result in results:
            meta = self._parse(result, entities)
            if meta is not None:
                metas.append(meta)
        return metas

    def _fetch_entities(
        self, uris: list[str], timeout: float
    ) -> dict[str, dict]:
        entities: dict[str, dict] = {}
        for start in range(0, len(uris), _BATCH):
            chunk = uris[start:start + _BATCH]
            if not chunk:
                continue
            try:
                resp = requests.get(
                    ENTITIES_URL,
                    params={
                        "action": "by-uris",
                        "uris": "|".join(chunk),
                    },
                    timeout=timeout,
                )
                resp.raise_for_status()
                data = resp.json()
            except Exception as exc:
                log.warning("Inventaire entity fetch failed: %s", exc)
                continue
            entities.update(data.get("entities") or {})
        return entities

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
            log.warning("Inventaire cover download failed: %s", exc)
            return None

    def _parse(
        self, result: dict, entities: dict[str, dict]
    ) -> Metadata | None:
        entity = entities.get(result.get("uri", ""))
        if not entity:
            return None
        work = None
        for uri in _claims(entity, "P629"):
            work = entities.get(uri)
            if work:
                break

        title = _label_en(entity) or _label_en(work)
        if not title:
            return None
        author_uris = _claims(entity, "P50") or _claims(work, "P50")
        authors = [
            label for label in (
                _label_en(entities.get(uri)) for uri in author_uris
            ) if label
        ]
        publisher_uris = _claims(entity, "P123") or _claims(work, "P123")
        publishers = [
            label for label in (
                _label_en(entities.get(uri)) for uri in publisher_uris
            ) if label
        ]
        language_uris = _claims(entity, "P407") or _claims(work, "P407")
        languages = [
            label for label in (
                _label_en(entities.get(uri)) for uri in language_uris
            ) if label
        ]
        genre_uris = _claims(work, "P136") or _claims(entity, "P136")
        tags = [
            label for label in (
                _label_en(entities.get(uri)) for uri in genre_uris
            ) if label
        ][:8]
        isbn = (_claims(entity, "P212") or _claims(work, "P212") or [""])[0]
        date = (_claims(entity, "P577") or _claims(work, "P577") or [""])[0]
        description = (
            _description_en(entity) or _description_en(work)
        )
        image = (
            result.get("image")
            or entity.get("image")
            or (work.get("image") if work else "")
        )
        return Metadata(
            title=title,
            authors=authors,
            isbn=_clean_isbn(str(isbn)),
            publisher=publishers[0] if publishers else "",
            pubdate=str(date),
            language=languages[0] if languages else "English",
            description=description,
            tags=tags,
            cover_url=_image_url(image),
            source_id=f"inventaire:{entity.get('wdId') or result.get('id')}",
            source_name="Inventaire",
        )


def _claims(entity: dict | None, prop: str) -> list[str]:
    if not entity:
        return []
    values = (entity.get("claims") or {}).get(f"wdt:{prop}") or []
    return [str(value) for value in values]


def _label_en(entity: dict | None) -> str:
    if not entity:
        return ""
    return str((entity.get("labels") or {}).get("en") or "").strip()


def _description_en(entity: dict | None) -> str:
    if not entity:
        return ""
    value = (entity.get("descriptions") or {}).get("en") or ""
    return re.sub(r"\s+", " ", str(value)).strip()


def _image_url(value) -> str:
    value = str(value or "").strip()
    if not value:
        return ""
    if value.startswith("http://") or value.startswith("https://"):
        return value
    if value.startswith("/"):
        return BASE_URL + value
    return f"{BASE_URL}/img/entities/{value}"


def _clean_isbn(value: str) -> str:
    digits = re.sub(r"[^0-9Xx]", "", value)
    if len(digits) in (10, 13):
        return digits.upper()
    return ""

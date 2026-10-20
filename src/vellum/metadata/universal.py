"""Best-effort metadata extraction from an arbitrary book page URL.

Many book pages (publishers, bookstores, review sites) embed schema.org
JSON-LD, OpenGraph tags, or microdata. This grabber reads those instead of
depending on a site-specific API, so it works across sources.
"""

from __future__ import annotations

import html as html_lib
import json
import logging
import re
from urllib.parse import urljoin, urlparse, urlsplit

import requests
from bs4 import BeautifulSoup

from vellum.metadata.sources.base import Metadata, MetadataSource

log = logging.getLogger(__name__)

USER_AGENT = (
    "Vellum/0.1 (+https://github.com/PuppyCodingBadly/vellum) "
    "metadata grabber"
)
MAX_HTML_BYTES = 4 * 1024 * 1024
MAX_COVER_BYTES = 10 * 1024 * 1024
_BOOK_TYPES = {"book", "audiobook", "product", "creativework"}


class UniversalGrabber(MetadataSource):
    """Extract metadata from a URL using JSON-LD, OpenGraph, and microdata."""

    id = "universal-url"
    name = "Web page"

    def search(self, *args, **kwargs) -> list[Metadata]:
        # URL grabbing is explicit; there is nothing to search by title.
        return []

    def grab(self, url: str, timeout: float = 20.0) -> Metadata | None:
        url = normalize_url(url)
        if not url:
            raise ValueError("enter a valid http(s) URL")
        try:
            html, final_url = _fetch_html(url, timeout)
        except Exception as exc:
            log.warning("Universal metadata grab failed for %s: %s", url, exc)
            raise
        meta = parse_book_page(html, final_url)
        if meta is None:
            return None
        meta.source_id = f"universal:{final_url}"
        if not meta.source_name:
            meta.source_name = urlparse(final_url).netloc
        return meta

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        if not meta.cover_url:
            return None
        try:
            return _fetch_cover(meta.cover_url, timeout)
        except Exception as exc:
            log.warning("Universal cover download failed: %s", exc)
            return None


def normalize_url(url: str) -> str:
    """Return a validated http(s) URL, or "" for a search string/invalid input.

    Free-form metadata searches are often pasted into the URL field by
    mistake; rejecting whitespace and host-less strings here lets the UI
    route them to fuzzy search instead of raising requests' opaque
    "invalid character" errors.
    """
    url = (url or "").strip()
    if not url or any(char.isspace() for char in url):
        return ""
    if not re.match(r"^https?://", url, re.IGNORECASE):
        url = "https://" + url
    try:
        parts = urlsplit(url)
        host = parts.hostname or ""
    except ValueError:
        return ""
    if parts.scheme.lower() not in ("http", "https") or not parts.netloc:
        return ""
    if any(char.isspace() for char in parts.netloc):
        return ""
    if "." not in host and host != "localhost":
        return ""
    if "://" not in url:
        return ""
    return url


def _fetch_html(url: str, timeout: float) -> tuple[str, str]:
    resp = requests.get(
        url,
        timeout=timeout,
        headers={"User-Agent": USER_AGENT},
        stream=True,
    )
    resp.raise_for_status()
    content_type = (resp.headers.get("Content-Type") or "").lower()
    if content_type and "html" not in content_type and "xml" not in content_type:
        raise ValueError(f"not an HTML page ({content_type})")

    chunks: list[bytes] = []
    size = 0
    for chunk in resp.iter_content(64 * 1024):
        if not chunk:
            continue
        size += len(chunk)
        if size > MAX_HTML_BYTES:
            break
        chunks.append(chunk)
    resp.close()
    body = b"".join(chunks)
    encoding = resp.encoding or "utf-8"
    return body.decode(encoding, errors="replace"), resp.url or url


def _fetch_cover(url: str, timeout: float) -> bytes | None:
    if not re.match(r"^https?://", url, re.IGNORECASE):
        return None
    resp = requests.get(
        url,
        timeout=timeout,
        headers={"User-Agent": USER_AGENT},
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


def parse_book_page(html: str, base_url: str = "") -> Metadata | None:
    """Parse a book page into Metadata using every embedded convention."""
    soup = BeautifulSoup(html, "html.parser")
    fields: dict = {}

    for obj in _jsonld_objects(soup):
        if _is_book_type(obj):
            _merge_missing(fields, _fields_from_jsonld(obj, base_url))

    _merge_missing(fields, _fields_from_meta(soup, base_url))
    _merge_missing(fields, _fields_from_microdata(soup, base_url))

    title = fields.get("title") or _clean(
        soup.title.get_text(" ", strip=True) if soup.title else ""
    )
    if not title:
        return None

    rating = fields.get("rating", 0.0)
    tags = fields.get("tags", [])
    meta = Metadata(
        title=title,
        authors=fields.get("authors", []),
        isbn=fields.get("isbn", ""),
        publisher=fields.get("publisher", ""),
        pubdate=fields.get("pubdate", ""),
        language=fields.get("language", ""),
        description=fields.get("description", ""),
        tags=tags,
        rating=_clamp_rating(rating),
        cover_url=fields.get("cover_url", ""),
        source_name=fields.get("site_name", ""),
    )
    return meta


# -- JSON-LD -----------------------------------------------------------------


def _jsonld_objects(soup: BeautifulSoup) -> list[dict]:
    objects: list[dict] = []
    for script in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = script.string or script.get_text()
        if not raw.strip():
            continue
        try:
            data = json.loads(html_lib.unescape(raw))
        except (TypeError, ValueError):
            continue
        objects.extend(_flatten_jsonld(data))
    return objects


def _flatten_jsonld(data) -> list[dict]:
    if isinstance(data, list):
        result: list[dict] = []
        for item in data:
            result.extend(_flatten_jsonld(item))
        return result
    if not isinstance(data, dict):
        return []
    graph = data.get("@graph")
    if isinstance(graph, list):
        return _flatten_jsonld(graph)
    return [data]


def _is_book_type(obj: dict) -> bool:
    types = obj.get("@type") or obj.get("type") or ""
    if isinstance(types, str):
        types = [types]
    if not isinstance(types, list):
        return False
    return any(str(value).rsplit("/", 1)[-1].lower() in _BOOK_TYPES for value in types)


def _fields_from_jsonld(obj: dict, base_url: str) -> dict:
    fields: dict = {}
    fields["title"] = _clean(_as_text(obj.get("name") or obj.get("headline")))
    authors = _names(obj.get("author"))
    if authors:
        fields["authors"] = authors
    isbn = _jsonld_isbn(obj)
    if isbn:
        fields["isbn"] = isbn
    publisher = _as_text(obj.get("publisher"))
    if publisher:
        fields["publisher"] = publisher
    pubdate = _as_text(
        obj.get("datePublished") or obj.get("dateCreated") or obj.get("releaseDate")
    )
    if pubdate:
        fields["pubdate"] = pubdate
    language = _as_text(obj.get("inLanguage"))
    if language:
        fields["language"] = language
    description = _clean(_as_text(obj.get("description")))
    if description:
        fields["description"] = description
    image = _first_url(obj.get("image") or obj.get("thumbnailUrl"), base_url)
    if image:
        fields["cover_url"] = image
    rating = _jsonld_rating(obj.get("aggregateRating"))
    if rating:
        fields["rating"] = rating
    tags = _split_tags(obj.get("genre") or obj.get("keywords"))
    if tags:
        fields["tags"] = tags
    return {key: value for key, value in fields.items() if value}


def _jsonld_isbn(obj: dict) -> str:
    candidates = []
    if obj.get("isbn"):
        candidates.append(obj["isbn"])
    identifier = obj.get("identifier")
    if isinstance(identifier, list):
        candidates.extend(identifier)
    elif identifier:
        candidates.append(identifier)
    for candidate in candidates:
        if isinstance(candidate, dict):
            value = candidate.get("value") or candidate.get("identifier")
            kind = str(
                candidate.get("propertyID")
                or candidate.get("name")
                or candidate.get("@type")
                or ""
            ).lower()
            if value and (not kind or "isbn" in kind):
                return _clean(str(value))
        elif candidate:
            return _clean(str(candidate))
    for key in ("gtin13", "gtin", "sku"):
        if obj.get(key):
            return _clean(str(obj[key]))
    return ""


def _jsonld_rating(rating) -> float:
    if not isinstance(rating, dict):
        return 0.0
    try:
        value = float(rating.get("ratingValue"))
        best = float(rating.get("bestRating") or 5)
    except (TypeError, ValueError):
        return 0.0
    if best <= 0:
        return 0.0
    return _clamp_rating(value * 5.0 / best)


# -- meta tags ---------------------------------------------------------------


def _fields_from_meta(soup: BeautifulSoup, base_url: str) -> dict:
    def values(*names: str) -> list[str]:
        found: list[str] = []
        for name in names:
            for tag in soup.find_all("meta", attrs={"property": name}):
                if tag.get("content"):
                    found.append(_clean(tag["content"]))
            for tag in soup.find_all("meta", attrs={"name": name}):
                if tag.get("content"):
                    found.append(_clean(tag["content"]))
        return found

    def content(*names: str) -> str:
        found = values(*names)
        return found[0] if found else ""

    fields: dict = {}
    title = content("og:title", "twitter:title")
    if title:
        fields["title"] = title
    authors = _split_list(values("book:author", "og:book:author", "author"))
    if authors:
        fields["authors"] = authors
    isbn = content("book:isbn", "og:book:isbn", "isbn")
    if isbn:
        fields["isbn"] = isbn
    publisher = content("book:publisher", "og:book:publisher", "publisher")
    if publisher:
        fields["publisher"] = publisher
    pubdate = content(
        "book:release_date",
        "og:book:release_date",
        "article:published_time",
        "date",
    )
    if pubdate:
        fields["pubdate"] = pubdate
    language = content("og:locale", "language")
    if language:
        fields["language"] = language
    description = content("og:description", "twitter:description", "description")
    if description:
        fields["description"] = description
    cover = content("og:image:secure_url", "og:image", "twitter:image", "image")
    if cover:
        cover = _absolute(cover, base_url)
        if cover:
            fields["cover_url"] = cover
    tags = _split_tags(values("book:tag", "article:tag", "keywords"))
    if tags:
        fields["tags"] = tags
    site_name = content("og:site_name")
    if site_name:
        fields["site_name"] = site_name
    return fields


# -- microdata ---------------------------------------------------------------


def _fields_from_microdata(soup: BeautifulSoup, base_url: str) -> dict:
    scopes = soup.select(
        '[itemtype*="Book"], [itemtype*="Product"], [itemtype*="CreativeWork"]'
    )
    scope = scopes[0] if scopes else soup

    def value(name: str) -> str:
        tag = scope.select_one(f'[itemprop="{name}"]')
        if tag is None:
            return ""
        return _clean(
            tag.get("content")
            or tag.get("href")
            or tag.get("src")
            or tag.get_text(" ", strip=True)
        )

    fields: dict = {}
    title = value("name")
    if title:
        fields["title"] = title
    author = value("author")
    if author:
        fields["authors"] = [author]
    isbn = value("isbn")
    if isbn:
        fields["isbn"] = isbn
    publisher = value("publisher")
    if publisher:
        fields["publisher"] = publisher
    pubdate = value("datePublished")
    if pubdate:
        fields["pubdate"] = pubdate
    description = value("description")
    if description:
        fields["description"] = description
    language = value("inLanguage")
    if language:
        fields["language"] = language
    image = value("image")
    if image:
        image = _absolute(image, base_url)
        if image:
            fields["cover_url"] = image
    return fields


# -- helpers -----------------------------------------------------------------


def _merge_missing(target: dict, source: dict) -> None:
    for key, value in source.items():
        if key not in target or not target[key]:
            target[key] = value


def _as_text(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return _as_text(value.get("name") or value.get("@value") or value.get("value"))
    if isinstance(value, list):
        return _as_text(value[0]) if value else ""
    return ""


def _names(value) -> list[str]:
    values = value if isinstance(value, list) else [value]
    names: list[str] = []
    for item in values:
        name = _clean(_as_text(item))
        if name and name not in names:
            names.append(name)
    return names


def _split_tags(value) -> list[str]:
    values = value if isinstance(value, list) else [value]
    tags: list[str] = []
    for item in values:
        for tag in re.split(r"[,;]", str(item or "")):
            tag = _clean(tag)
            if tag and tag not in tags:
                tags.append(tag)
    return tags[:12]


def _split_list(value) -> list[str]:
    """Split repeated meta values without treating author commas as separators."""
    values = value if isinstance(value, list) else [value]
    items: list[str] = []
    for item in values:
        text = _clean(item)
        if text and text not in items:
            items.append(text)
    return items


def _first_url(value, base_url: str) -> str:
    values = value if isinstance(value, list) else [value]
    for item in values:
        url = item.get("url") or item.get("contentUrl") if isinstance(item, dict) else item
        url = _absolute(_as_text(url), base_url)
        if url:
            return url
    return ""


def _absolute(value: str, base_url: str) -> str:
    value = (value or "").strip()
    if not value:
        return ""
    if value.startswith("//"):
        return "https:" + value
    if re.match(r"^https?://", value, re.IGNORECASE):
        return value
    if base_url:
        return urljoin(base_url, value)
    return ""


def _clean(value) -> str:
    text = str(value or "")
    if "<" in text and ">" in text:
        text = BeautifulSoup(text, "html.parser").get_text(" ", strip=True)
    return re.sub(r"\s+", " ", text).strip()


def _clamp_rating(value) -> float:
    try:
        rating = float(value)
    except (TypeError, ValueError):
        return 0.0
    return round(max(0.0, min(5.0, rating)), 1)

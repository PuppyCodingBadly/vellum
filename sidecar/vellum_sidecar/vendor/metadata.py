"""Base types for metadata sources."""

from __future__ import annotations

import http.client
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

from .budget import Budget

#: Byte budget for one cover body, matching ``maxCoverBytes`` in the Dart client.
MAX_COVER_BYTES = 10 * 1024 * 1024


@dataclass
class Metadata:
    title: str = ""
    authors: list[str] = field(default_factory=list)
    isbn: str = ""
    publisher: str = ""
    pubdate: str = ""
    language: str = ""
    description: str = ""
    tags: list[str] = field(default_factory=list)
    rating: float = 0.0
    cover_url: str = ""
    source_id: str = ""
    source_name: str = ""


class MetadataSource:
    """Base class for metadata providers.

    ``budget`` is the request's shared deadline: a call must pass what is
    left of it to the plugin, never a fresh full timeout.
    """

    id: str = ""
    name: str = ""

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        budget: Budget | None = None,
    ) -> list[Metadata]:
        raise NotImplementedError

    def search_free_text(
        self, query: str, budget: Budget | None = None
    ) -> list[Metadata]:
        """Fuzzy search by a free-form string.

        Sources with a full-text endpoint should override this; the
        fallback passes the string as a title query, preserving the
        plugin interface.
        """
        return self.search(title=query, budget=budget)

    def download_cover(self, meta: Metadata,
                       budget: Budget | None = None) -> bytes | None:
        raise NotImplementedError


class _SameSchemeRedirects(urllib.request.HTTPRedirectHandler):
    """Follow redirects only while they keep the original URL's scheme."""

    def __init__(self, scheme: str):
        self._scheme = scheme

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlsplit(newurl)
        if target.scheme != self._scheme:
            raise urllib.error.URLError(
                f"refusing redirect to {target.scheme or 'unknown'} URL"
            )
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch_cover_bytes(
    url: str, timeout: float, max_bytes: int = MAX_COVER_BYTES
) -> bytes | None:
    """Fetch ``url`` as cover image bytes, or None when it is not a safe image.

    Plugins decide ``cover_url``, so this is the single gate for cover
    downloads: only http(s) URLs are fetched, redirects stay on the same
    scheme, a declared content type must be ``image/*``, and the body read
    stops one byte past ``max_bytes`` so an endless response is rejected
    instead of buffered.  Transport failures also read as "no cover".
    """
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        return None
    opener = urllib.request.build_opener(_SameSchemeRedirects(parts.scheme))
    try:
        with opener.open(url, timeout=timeout) as resp:
            if not 200 <= resp.status < 400:
                return None
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if content_type and not content_type.startswith("image/"):
                return None
            body = resp.read(max_bytes + 1)
            return None if len(body) > max_bytes else body
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError):
        return None

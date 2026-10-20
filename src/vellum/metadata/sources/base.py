"""Base types for metadata sources."""

from __future__ import annotations

from dataclasses import dataclass, field


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
    """Base class for metadata providers."""

    id: str = ""
    name: str = ""

    def search(
        self,
        title: str = "",
        authors: list[str] | None = None,
        isbn: str = "",
        timeout: float = 15.0,
    ) -> list[Metadata]:
        raise NotImplementedError

    def download_cover(self, meta: Metadata, timeout: float = 15.0) -> bytes | None:
        raise NotImplementedError

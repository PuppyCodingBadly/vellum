"""Core data models for vellum."""

from dataclasses import dataclass, field


@dataclass
class Author:
    name: str
    sort: str = ""


@dataclass
class Book:
    id: int | None = None
    title: str = ""
    authors: list[str] = field(default_factory=list)
    sort: str = ""
    isbn: str = ""
    publisher: str = ""
    pubdate: str = ""
    language: str = ""
    description: str = ""
    tags: list[str] = field(default_factory=list)
    formats: list[str] = field(default_factory=list)
    cover_path: str = ""
    path: str = ""
    rating: float = 0.0
    added: str = ""

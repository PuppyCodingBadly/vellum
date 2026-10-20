"""Stable sorting for the library grid."""

from __future__ import annotations

from vellum.core.models import Book

SORT_OPTIONS = (
    ("title", "Title"),
    ("author", "Author"),
    ("rating", "Rating"),
    ("added", "Recently added"),
)
SORT_KEYS = tuple(key for key, _label in SORT_OPTIONS)


def _title(book: Book) -> str:
    return (book.title or "Untitled").casefold()


def _author(book: Book) -> str:
    return (", ".join(book.authors) or "\uffff").casefold()


def sort_books(books: list[Book], key: str = "title") -> list[Book]:
    """Return a new list sorted by *key* (unknown keys fall back to title)."""
    items = list(books)
    if key == "author":
        return sorted(items, key=lambda book: (_author(book), _title(book)))
    if key == "rating":
        return sorted(
            items, key=lambda book: (-(book.rating or 0.0), _title(book))
        )
    if key == "added":
        present = [book for book in items if book.added]
        missing = [book for book in items if not book.added]
        present.sort(
            key=lambda book: (book.added, _title(book)), reverse=True
        )
        return present + sorted(missing, key=_title)
    return sorted(items, key=_title)

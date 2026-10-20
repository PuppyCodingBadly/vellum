"""Tests for library and metadata result sorting."""

from __future__ import annotations

from vellum.core.models import Book
from vellum.core.sorting import sort_books
from vellum.metadata.sources.base import Metadata
from vellum.metadata.sorting import sort_metadata


def test_sort_books_by_title_author_rating_added():
    zed = Book(title="Zed", authors=["B"], rating=2.0, added="2024-01-01")
    apple = Book(title="Apple", authors=["A"], rating=4.0, added="2023-01-01")
    mango = Book(title="Mango", authors=["C"], rating=5.0, added="2025-01-01")

    assert [b.title for b in sort_books([zed, apple, mango], "title")] == [
        "Apple", "Mango", "Zed",
    ]
    assert [b.title for b in sort_books([zed, apple, mango], "author")] == [
        "Apple", "Zed", "Mango",
    ]
    assert [b.title for b in sort_books([zed, apple, mango], "rating")] == [
        "Mango", "Apple", "Zed",
    ]
    assert [b.title for b in sort_books([zed, apple, mango], "added")] == [
        "Mango", "Zed", "Apple",
    ]


def test_sort_books_unknown_key_falls_back_to_title():
    books = [Book(title="B"), Book(title="A")]
    assert [b.title for b in sort_books(books, "nonsense")] == ["A", "B"]


def test_sort_metadata_by_title_author_rating_and_newest():
    merged = Metadata(title="Merged", source_id="merged")
    b = Metadata(title="Beta", authors=["Zed"], rating=2.0, pubdate="2000")
    a = Metadata(title="Alpha", authors=["Amy"], rating=4.0, pubdate="2020")

    results = sort_metadata([b, merged, a], "title")
    assert [m.title for m in results] == ["Merged", "Alpha", "Beta"]

    results = sort_metadata([b, merged, a], "author")
    assert [m.title for m in results] == ["Merged", "Alpha", "Beta"]

    results = sort_metadata([b, merged, a], "rating")
    assert [m.title for m in results] == ["Merged", "Alpha", "Beta"]

    results = sort_metadata([b, merged, a], "pubdate")
    assert [m.title for m in results] == ["Merged", "Alpha", "Beta"]


def test_sort_metadata_relevance_preserves_order():
    first = Metadata(title="First")
    second = Metadata(title="Second")
    assert sort_metadata([first, second], "relevance") == [first, second]

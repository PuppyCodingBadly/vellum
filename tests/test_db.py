"""Tests for vellum.core.db.Library."""

import pytest

from vellum.core.db import Library
from vellum.core.models import Book


@pytest.fixture
def lib(tmp_path):
    library = Library(str(tmp_path / "library.db"))
    library.open()
    yield library
    library.close()


def make_book(**kwargs):
    defaults = dict(
        title="The Left Hand of Darkness",
        authors=["Ursula K. Le Guin"],
        isbn="9780441478125",
        tags=["sci-fi", "classic"],
        formats=["epub"],
        path="/books/lefthand.epub",
    )
    defaults.update(kwargs)
    return Book(**defaults)


def test_add_get_round_trip(lib):
    book = make_book()
    book_id = lib.add_book(book)
    assert isinstance(book_id, int)
    assert book.id == book_id
    assert book.added  # timestamp set

    fetched = lib.get_book(book_id)
    assert fetched is not None
    assert fetched.title == "The Left Hand of Darkness"
    assert fetched.authors == ["Ursula K. Le Guin"]
    assert fetched.tags == ["classic", "sci-fi"]
    assert fetched.formats == ["epub"]
    assert fetched.isbn == "9780441478125"
    assert fetched.added == book.added


def test_get_missing_returns_none(lib):
    assert lib.get_book(9999) is None


def test_search_by_title_author_tag(lib):
    lib.add_book(make_book())
    lib.add_book(
        make_book(
            title="Dune",
            authors=["Frank Herbert"],
            isbn="9780441172719",
            tags=["sci-fi", "desert"],
        )
    )

    results = lib.search("left hand")
    assert [b.title for b in results] == ["The Left Hand of Darkness"]

    results = lib.search("le guin")
    assert [b.title for b in results] == ["The Left Hand of Darkness"]

    results = lib.search("classic")
    assert [b.title for b in results] == ["The Left Hand of Darkness"]

    # AND across tokens: both books are sci-fi but only one matches "dune".
    results = lib.search("sci-fi dune")
    assert [b.title for b in results] == ["Dune"]

    results = lib.search("herbert sci-fi")
    assert [b.title for b in results] == ["Dune"]

    # No match when one token matches nothing.
    assert lib.search("dune nonexistenttoken") == []

    # Case-insensitive.
    results = lib.search("DUNE")
    assert [b.title for b in results] == ["Dune"]


def test_search_by_isbn(lib):
    lib.add_book(make_book())
    results = lib.search("9780441478125")
    assert [b.title for b in results] == ["The Left Hand of Darkness"]


def test_update_book_replaces_links(lib):
    book_id = lib.add_book(make_book())
    book = lib.get_book(book_id)
    book.title = "The Dispossessed"
    book.authors = ["Ursula K. Le Guin", "Some Editor"]
    book.tags = ["utopia"]
    book.formats = ["epub", "pdf"]
    lib.update_book(book)

    fetched = lib.get_book(book_id)
    assert fetched.title == "The Dispossessed"
    assert fetched.authors == ["Ursula K. Le Guin", "Some Editor"]
    assert fetched.tags == ["utopia"]
    assert fetched.formats == ["epub", "pdf"]

    # Old tag no longer matches.
    assert lib.search("classic") == []


def test_update_unknown_id_raises(lib):
    with pytest.raises(KeyError):
        lib.update_book(make_book(id=12345))


def test_delete_book_cascades(lib):
    book_id = lib.add_book(make_book())
    lib.delete_book(book_id)
    assert lib.get_book(book_id) is None
    assert lib.search("classic") == []

    # Re-adding the same book works fine after cascade delete.
    new_id = lib.add_book(make_book())
    assert lib.get_book(new_id).authors == ["Ursula K. Le Guin"]


def test_duplicate_authors_reused(lib):
    id1 = lib.add_book(make_book())
    id2 = lib.add_book(make_book(title="The Dispossessed", isbn="9780061054884"))
    assert id1 != id2
    # Both books share the same author; search finds both, no error on reinsert.
    results = lib.search("le guin")
    assert {b.title for b in results} == {
        "The Left Hand of Darkness",
        "The Dispossessed",
    }


def test_all_books_sorted_by_title(lib):
    lib.add_book(make_book(title="Zebra"))
    lib.add_book(make_book(title="Apple"))
    lib.add_book(make_book(title="Mango"))
    assert [b.title for b in lib.all_books()] == ["Apple", "Mango", "Zebra"]

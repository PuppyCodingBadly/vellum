"""Tests for vellum.core.db.Library."""

import zipfile

import pytest

from vellum.core.db import Library
from vellum.core.importer import import_path
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


def test_highlights_add_list_delete(lib):
    book_id = lib.add_book(make_book())
    first = lib.add_highlight(book_id, '{"chapter": 1, "start": 0, "end": 5}', "yellow", "hello")
    second = lib.add_highlight(book_id, '{"chapter": 2, "start": 3, "end": 9}', "pink", "world")
    assert isinstance(first, int)
    assert second != first

    highlights = lib.list_highlights(book_id)
    assert [h["id"] for h in highlights] == [first, second]  # created order
    assert highlights[0]["book_id"] == book_id
    assert highlights[0]["color"] == "yellow"
    assert highlights[0]["text"] == "hello"
    assert highlights[0]["created"]
    assert highlights[1]["color"] == "pink"

    lib.delete_highlight(first)
    highlights = lib.list_highlights(book_id)
    assert [h["id"] for h in highlights] == [second]


def test_highlights_cascade_on_delete_book(lib):
    book_id = lib.add_book(make_book())
    lib.add_highlight(book_id, "epub:1:0.5", "green", "quote")
    lib.set_reading_position(book_id, "epub:1:0.5")
    lib.delete_book(book_id)
    assert lib.list_highlights(book_id) == []
    assert lib.get_reading_position(book_id) is None


def test_highlights_unknown_book_empty(lib):
    assert lib.list_highlights(9999) == []


def test_reading_position_set_get_overwrite(lib):
    book_id = lib.add_book(make_book())
    assert lib.get_reading_position(book_id) is None
    lib.set_reading_position(book_id, "epub:3:0.42")
    assert lib.get_reading_position(book_id) == "epub:3:0.42"
    lib.set_reading_position(book_id, "epub:4:0.10")
    assert lib.get_reading_position(book_id) == "epub:4:0.10"


def test_reading_position_unknown_book_none(lib):
    assert lib.get_reading_position(9999) is None


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


_OPF_SCHEME_ISBN = """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
  <metadata>
    <dc:title>Scheme ISBN Book</dc:title>
    <dc:creator>Jane Author</dc:creator>
    <dc:identifier id="bid" opf:scheme="ISBN">9780306406157</dc:identifier>
  </metadata>
  <manifest/>
  <spine/>
</package>"""

_CONTAINER = """<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
              media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""


def _write_epub(path, opf):
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("META-INF/container.xml", _CONTAINER)
        zf.writestr("OEBPS/content.opf", opf)


def test_import_epub_isbn_via_opf_scheme(lib, tmp_path):
    epub = tmp_path / "scheme.epub"
    _write_epub(epub, _OPF_SCHEME_ISBN)

    ids = import_path(lib, str(epub))
    assert len(ids) == 1
    book = lib.get_book(ids[0])
    assert book.isbn == "9780306406157"
    assert book.title == "Scheme ISBN Book"
    assert book.authors == ["Jane Author"]


def test_memory_library_roundtrip():
    library = Library(":memory:")
    library.open()
    book = Book(title="Memory Book", authors=["Ada"])
    book_id = library.add_book(book)
    assert library.get_book(book_id).title == "Memory Book"
    library.close()

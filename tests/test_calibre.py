"""Tests for importing a calibre library folder."""

from __future__ import annotations

import os
import sqlite3

import pytest

from vellum.core.calibre import (
    _html_to_text,
    import_calibre_library,
    is_calibre_library,
)
from vellum.core.db import Library

_CALIBRE_SCHEMA = """
CREATE TABLE books (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    sort TEXT NOT NULL DEFAULT '',
    timestamp TEXT,
    pubdate TEXT,
    path TEXT NOT NULL DEFAULT '',
    has_cover INTEGER NOT NULL DEFAULT 0,
    isbn TEXT NOT NULL DEFAULT '',
    uuid TEXT
);
CREATE TABLE authors (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT, link TEXT
);
CREATE TABLE books_authors_link (
    id INTEGER PRIMARY KEY, book INTEGER, author INTEGER
);
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE books_tags_link (
    id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER
);
CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE books_publishers_link (
    id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER
);
CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
CREATE TABLE books_ratings_link (
    id INTEGER PRIMARY KEY, book INTEGER, rating INTEGER
);
CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT NOT NULL);
CREATE TABLE books_languages_link (
    id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER, item_order INTEGER
);
CREATE TABLE identifiers (
    id INTEGER PRIMARY KEY, book INTEGER, type TEXT, value TEXT
);
CREATE TABLE data (
    id INTEGER PRIMARY KEY, book INTEGER, format TEXT,
    uncompressed_size INTEGER, name TEXT
);
"""


@pytest.fixture
def lib(tmp_path):
    library = Library(str(tmp_path / "vellum.db"))
    library.open()
    yield library
    library.close()


@pytest.fixture
def calibre_library(tmp_path):
    root = tmp_path / "Calibre Library"
    book_dir = root / "Jane Author" / "A Book (1)"
    book_dir.mkdir(parents=True)
    (book_dir / "Book.epub").write_bytes(b"epub")
    (book_dir / "Book.pdf").write_bytes(b"pdf")
    (book_dir / "cover.jpg").write_bytes(b"jpeg")

    conn = sqlite3.connect(root / "metadata.db")
    conn.executescript(_CALIBRE_SCHEMA)
    conn.execute(
        "INSERT INTO books (id, title, sort, pubdate, path, has_cover, uuid)"
        " VALUES (1, 'A Book', 'Book, A', '2001-02-03 00:00:00+00:00',"
        " 'Jane Author/A Book (1)', 1, 'uuid-1')"
    )
    conn.execute("INSERT INTO authors (id, name) VALUES (1, 'Jane Author')")
    conn.execute(
        "INSERT INTO books_authors_link (book, author) VALUES (1, 1)"
    )
    conn.execute("INSERT INTO tags (id, name) VALUES (1, 'Fantasy')")
    conn.execute("INSERT INTO tags (id, name) VALUES (2, 'Adventure')")
    conn.execute("INSERT INTO books_tags_link (book, tag) VALUES (1, 1)")
    conn.execute("INSERT INTO books_tags_link (book, tag) VALUES (1, 2)")
    conn.execute("INSERT INTO publishers (id, name) VALUES (1, 'Acme Press')")
    conn.execute(
        "INSERT INTO books_publishers_link (book, publisher) VALUES (1, 1)"
    )
    conn.execute(
        "INSERT INTO comments (book, text) VALUES"
        " (1, '<p>First <b>para</b>.</p><p>Second &amp; last.</p>')"
    )
    conn.execute("INSERT INTO ratings (id, rating) VALUES (1, 9)")
    conn.execute("INSERT INTO books_ratings_link (book, rating) VALUES (1, 1)")
    conn.execute("INSERT INTO languages (id, lang_code) VALUES (1, 'eng')")
    conn.execute(
        "INSERT INTO books_languages_link (book, lang_code, item_order)"
        " VALUES (1, 1, 1)"
    )
    conn.execute(
        "INSERT INTO identifiers (book, type, value) VALUES"
        " (1, 'isbn', '9781234567890')"
    )
    conn.execute(
        "INSERT INTO data (book, format, name) VALUES (1, 'EPUB', 'Book')"
    )
    conn.execute(
        "INSERT INTO data (book, format, name) VALUES (1, 'PDF', 'Book')"
    )
    conn.commit()
    conn.close()
    return root


def test_is_calibre_library(calibre_library, tmp_path):
    assert is_calibre_library(str(calibre_library)) is True
    empty = tmp_path / "empty"
    empty.mkdir()
    assert is_calibre_library(str(empty)) is False


def test_import_calibre_library(lib, calibre_library):
    result = import_calibre_library(lib, str(calibre_library))
    assert result.added == 1
    assert result.skipped == 0
    assert result.failed == 0

    books = lib.all_books(include_hidden=True)
    assert len(books) == 1
    book = books[0]
    assert book.title == "A Book"
    assert book.authors == ["Jane Author"]
    assert book.isbn == "9781234567890"
    assert book.publisher == "Acme Press"
    assert book.pubdate == "2001"
    assert book.language == "eng"
    assert book.rating == 4.5
    assert book.formats == ["epub", "pdf"]
    book_dir = calibre_library / "Jane Author" / "A Book (1)"
    assert book.path == str(book_dir / "Book.epub")
    assert book.cover_path == str(book_dir / "cover.jpg")
    assert book.source_id == "calibre:uuid-1"
    assert book.hidden is False
    assert "First para." in book.description
    assert "Second & last." in book.description


def test_reimport_skips_existing_books(lib, calibre_library):
    assert import_calibre_library(lib, str(calibre_library)).added == 1
    second = import_calibre_library(lib, str(calibre_library))
    assert second.added == 0
    assert second.skipped == 1
    assert len(lib.all_books(include_hidden=True)) == 1


def test_reimport_skips_hidden_book(lib, calibre_library):
    import_calibre_library(lib, str(calibre_library))
    book = lib.all_books(include_hidden=True)[0]
    lib.set_hidden(book.id, True)
    second = import_calibre_library(lib, str(calibre_library))
    assert second.skipped == 1
    assert lib.get_book(book.id).hidden is True


def test_missing_metadata_raises(lib, tmp_path):
    with pytest.raises(ValueError):
        import_calibre_library(lib, str(tmp_path))


def test_html_to_text_blocks_and_entities():
    assert _html_to_text("<p>One</p><p>Two &amp; three</p>") == "One\nTwo & three"


def test_format_path_outside_library_is_ignored(lib, calibre_library):
    conn = sqlite3.connect(calibre_library / "metadata.db")
    conn.execute("UPDATE books SET path = '../escape'")
    conn.commit()
    conn.close()

    result = import_calibre_library(lib, str(calibre_library))
    assert result.added == 1
    book = lib.all_books(include_hidden=True)[0]
    assert book.path == ""
    assert book.formats == []


def test_import_from_read_only_wal_library(lib, calibre_library):
    """A WAL calibre DB on a read-only mount must import from a snapshot."""
    db = calibre_library / "metadata.db"
    writer = sqlite3.connect(db)
    writer.execute("PRAGMA journal_mode=WAL")
    writer.execute(
        "INSERT INTO books (id, title, path, has_cover, uuid)"
        " VALUES (2, 'WAL Book', '', 0, 'uuid-2')"
    )
    writer.commit()
    assert (calibre_library / "metadata.db-wal").is_file()

    modes = {}
    try:
        for path in [calibre_library, *calibre_library.rglob("*")]:
            if path.is_file():
                modes[path] = path.stat().st_mode
                os.chmod(path, 0o444)
            elif path.is_dir():
                modes[path] = path.stat().st_mode
                os.chmod(path, 0o555)

        result = import_calibre_library(lib, str(calibre_library))
        assert result.added == 2
        titles = {b.title for b in lib.all_books(include_hidden=True)}
        assert titles == {"A Book", "WAL Book"}
    finally:
        for path, mode in modes.items():
            os.chmod(path, mode)
        writer.close()


def test_import_does_not_modify_calibre_database(lib, calibre_library):
    db = calibre_library / "metadata.db"
    before = db.read_bytes()

    import_calibre_library(lib, str(calibre_library))

    assert db.read_bytes() == before


def test_row_failure_does_not_abort_import(lib, calibre_library, monkeypatch):
    from vellum.core import calibre

    original = calibre._import_row

    def fail_first(conn, library, root, row):
        if row["id"] == 1:
            raise RuntimeError("boom")
        return original(conn, library, root, row)

    monkeypatch.setattr(calibre, "_import_row", fail_first)
    result = import_calibre_library(lib, str(calibre_library))
    assert result.failed == 1
    assert result.added == 0
    assert result.first_error.startswith("RuntimeError: boom")


def test_broken_optional_table_does_not_fail_book(lib, calibre_library):
    conn = sqlite3.connect(calibre_library / "metadata.db")
    conn.execute("DROP TABLE books_tags_link")
    conn.execute(
        "CREATE TABLE books_tags_link ("
        " id INTEGER PRIMARY KEY, book INTEGER, tag_id INTEGER)"
    )
    conn.commit()
    conn.close()

    result = import_calibre_library(lib, str(calibre_library))
    assert result.added == 1
    assert result.failed == 0
    assert lib.all_books(include_hidden=True)[0].tags == []

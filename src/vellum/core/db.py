"""SQLite-backed library database."""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from vellum.core.models import Book

_SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    sort TEXT NOT NULL DEFAULT '',
    isbn TEXT NOT NULL DEFAULT '',
    publisher TEXT NOT NULL DEFAULT '',
    pubdate TEXT NOT NULL DEFAULT '',
    language TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    cover_path TEXT NOT NULL DEFAULT '',
    path TEXT NOT NULL DEFAULT '',
    rating REAL NOT NULL DEFAULT 0.0,
    added TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS authors (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    sort TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS book_authors (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (book_id, author_id)
);
CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS book_tags (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, tag_id)
);
CREATE TABLE IF NOT EXISTS formats (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    format TEXT NOT NULL DEFAULT '',
    path TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (book_id, format)
);
"""


class Library:
    """A SQLite-backed ebook library."""

    def __init__(self, path: str) -> None:
        self.path = path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def open(self) -> None:
        with self._connect() as conn:
            conn.executescript(_SCHEMA)

    def close(self) -> None:
        # Connections are per-method; nothing persistent to close.
        pass

    # -- helpers -----------------------------------------------------------

    def _author_id(self, conn: sqlite3.Connection, name: str) -> int:
        row = conn.execute("SELECT id FROM authors WHERE name = ?", (name,)).fetchone()
        if row:
            return row[0]
        cur = conn.execute("INSERT INTO authors (name, sort) VALUES (?, '')", (name,))
        return cur.lastrowid

    def _tag_id(self, conn: sqlite3.Connection, name: str) -> int:
        row = conn.execute("SELECT id FROM tags WHERE name = ?", (name,)).fetchone()
        if row:
            return row[0]
        cur = conn.execute("INSERT INTO tags (name) VALUES (?)", (name,))
        return cur.lastrowid

    def _write_links(self, conn: sqlite3.Connection, book: Book) -> None:
        assert book.id is not None
        conn.execute("DELETE FROM book_authors WHERE book_id = ?", (book.id,))
        conn.execute("DELETE FROM book_tags WHERE book_id = ?", (book.id,))
        conn.execute("DELETE FROM formats WHERE book_id = ?", (book.id,))
        for pos, name in enumerate(book.authors):
            conn.execute(
                "INSERT INTO book_authors (book_id, author_id, position) VALUES (?, ?, ?)",
                (book.id, self._author_id(conn, name), pos),
            )
        for name in book.tags:
            conn.execute(
                "INSERT INTO book_tags (book_id, tag_id) VALUES (?, ?)",
                (book.id, self._tag_id(conn, name)),
            )
        for fmt in book.formats:
            conn.execute(
                "INSERT INTO formats (book_id, format, path) VALUES (?, ?, ?)",
                (book.id, fmt, book.path),
            )

    @staticmethod
    def _book_row(book: Book) -> tuple:
        return (
            book.title,
            book.sort,
            book.isbn,
            book.publisher,
            book.pubdate,
            book.language,
            book.description,
            book.cover_path,
            book.path,
            book.rating,
            book.added,
        )

    # -- public API ---------------------------------------------------------

    def add_book(self, book: Book) -> int:
        if not book.added:
            book.added = datetime.now(timezone.utc).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO books (title, sort, isbn, publisher, pubdate, language,"
                " description, cover_path, path, rating, added)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                self._book_row(book),
            )
            book.id = cur.lastrowid
            self._write_links(conn, book)
        return book.id

    def update_book(self, book: Book) -> None:
        if book.id is None:
            raise KeyError("book has no id")
        with self._connect() as conn:
            cur = conn.execute(
                "UPDATE books SET title=?, sort=?, isbn=?, publisher=?, pubdate=?,"
                " language=?, description=?, cover_path=?, path=?, rating=?, added=?"
                " WHERE id=?",
                self._book_row(book) + (book.id,),
            )
            if cur.rowcount == 0:
                raise KeyError(book.id)
            self._write_links(conn, book)

    def _hydrate(self, conn: sqlite3.Connection, book: Book) -> Book:
        book.authors = [
            r[0]
            for r in conn.execute(
                "SELECT a.name FROM authors a"
                " JOIN book_authors ba ON ba.author_id = a.id"
                " WHERE ba.book_id = ? ORDER BY ba.position",
                (book.id,),
            )
        ]
        book.tags = [
            r[0]
            for r in conn.execute(
                "SELECT t.name FROM tags t"
                " JOIN book_tags bt ON bt.tag_id = t.id"
                " WHERE bt.book_id = ? ORDER BY t.name",
                (book.id,),
            )
        ]
        book.formats = [
            r[0]
            for r in conn.execute(
                "SELECT format FROM formats WHERE book_id = ? ORDER BY format",
                (book.id,),
            )
        ]
        return book

    def _row_to_book(self, conn: sqlite3.Connection, row: tuple) -> Book:
        book = Book(
            id=row[0],
            title=row[1],
            sort=row[2],
            isbn=row[3],
            publisher=row[4],
            pubdate=row[5],
            language=row[6],
            description=row[7],
            cover_path=row[8],
            path=row[9],
            rating=row[10],
            added=row[11],
        )
        return self._hydrate(conn, book)

    _COLUMNS = (
        "id, title, sort, isbn, publisher, pubdate, language, description,"
        " cover_path, path, rating, added"
    )

    def get_book(self, book_id: int) -> Book | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM books WHERE id = ?", (book_id,)
            ).fetchone()
            if row is None:
                return None
            return self._row_to_book(conn, row)

    def all_books(self) -> list[Book]:
        with self._connect() as conn:
            rows = conn.execute(
                f"SELECT {self._COLUMNS} FROM books ORDER BY title"
            ).fetchall()
            return [self._row_to_book(conn, r) for r in rows]

    def search(self, query: str) -> list[Book]:
        tokens = query.split()
        if not tokens:
            return self.all_books()
        clause = (
            "(lower(b.title) LIKE ? OR lower(b.isbn) LIKE ?"
            " OR EXISTS (SELECT 1 FROM book_authors ba JOIN authors a"
            "   ON a.id = ba.author_id"
            "   WHERE ba.book_id = b.id AND lower(a.name) LIKE ?)"
            " OR EXISTS (SELECT 1 FROM book_tags bt JOIN tags t"
            "   ON t.id = bt.tag_id"
            "   WHERE bt.book_id = b.id AND lower(t.name) LIKE ?))"
        )
        sql = f"SELECT {', '.join('b.' + c.strip() for c in self._COLUMNS.split(','))} FROM books b"
        sql += " WHERE " + " AND ".join([clause] * len(tokens)) + " ORDER BY b.title"
        params: list[str] = []
        for token in tokens:
            like = f"%{token.lower()}%"
            params.extend([like, like, like, like])
        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
            return [self._row_to_book(conn, r) for r in rows]

    def delete_book(self, book_id: int) -> None:
        with self._connect() as conn:
            conn.execute("DELETE FROM books WHERE id = ?", (book_id,))

    # Convenience for importer: directory holding covers etc.
    @property
    def base_dir(self) -> Path:
        if self.path == ":memory:":
            return Path.cwd()
        return Path(self.path).resolve().parent

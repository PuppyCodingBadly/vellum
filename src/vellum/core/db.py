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
    added TEXT NOT NULL DEFAULT '',
    hidden INTEGER NOT NULL DEFAULT 0,
    source_id TEXT NOT NULL DEFAULT ''
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
CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    position TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    text TEXT NOT NULL,
    created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS reading_positions (
    book_id INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    locator TEXT NOT NULL,
    updated TEXT NOT NULL
);
"""

# Columns added after the initial 0.1.0 schema. ``open`` applies any that
# an existing library database is missing.
_MIGRATIONS = {
    "hidden": "ALTER TABLE books ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0",
    "source_id": "ALTER TABLE books ADD COLUMN source_id TEXT NOT NULL DEFAULT ''",
}


class Library:
    """A SQLite-backed ebook library."""

    def __init__(self, path: str) -> None:
        self.path = path
        self._memory_conn: sqlite3.Connection | None = None

    def _connect(self) -> sqlite3.Connection:
        if self.path == ":memory:":
            # Every connection to :memory: is a separate database, so an
            # in-memory library must reuse one connection.
            if self._memory_conn is None:
                self._memory_conn = sqlite3.connect(":memory:")
                self._memory_conn.execute("PRAGMA foreign_keys = ON")
            return self._memory_conn
        conn = sqlite3.connect(self.path)
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def open(self) -> None:
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            existing = {
                row[1] for row in conn.execute("PRAGMA table_info(books)")
            }
            for column, statement in _MIGRATIONS.items():
                if column not in existing:
                    conn.execute(statement)

    def close(self) -> None:
        # File-backed connections are per-method; only the in-memory
        # connection persists.
        if self._memory_conn is not None:
            self._memory_conn.close()
            self._memory_conn = None

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
            int(book.hidden),
            book.source_id,
        )

    # -- public API ---------------------------------------------------------

    def add_book(self, book: Book) -> int:
        if not book.added:
            book.added = datetime.now(timezone.utc).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO books (title, sort, isbn, publisher, pubdate, language,"
                " description, cover_path, path, rating, added, hidden, source_id)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
                " language=?, description=?, cover_path=?, path=?, rating=?, added=?,"
                " hidden=?, source_id=?"
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
            hidden=bool(row[12]),
            source_id=row[13],
        )
        return self._hydrate(conn, book)

    _COLUMNS = (
        "id, title, sort, isbn, publisher, pubdate, language, description,"
        " cover_path, path, rating, added, hidden, source_id"
    )

    def get_book(self, book_id: int) -> Book | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM books WHERE id = ?", (book_id,)
            ).fetchone()
            if row is None:
                return None
            return self._row_to_book(conn, row)

    def all_books(self, include_hidden: bool = False) -> list[Book]:
        with self._connect() as conn:
            where = "" if include_hidden else " WHERE hidden = 0"
            rows = conn.execute(
                f"SELECT {self._COLUMNS} FROM books{where} ORDER BY title"
            ).fetchall()
            return [self._row_to_book(conn, r) for r in rows]

    def search(self, query: str, include_hidden: bool = False) -> list[Book]:
        tokens = query.split()
        if not tokens:
            return self.all_books(include_hidden=include_hidden)
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
        conditions = [clause] * len(tokens)
        if not include_hidden:
            conditions.append("b.hidden = 0")
        sql += " WHERE " + " AND ".join(conditions) + " ORDER BY b.title"
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

    def delete_books_without_files(self, titles: set[str]) -> int:
        """Delete books with one of *titles* that have no path or formats.

        Used to clean up catalogue-only entries (for example the sample
        books older versions seeded) without touching real imported books.
        Returns the number of rows deleted.
        """
        if not titles:
            return 0
        placeholders = ", ".join("?" for _ in titles)
        with self._connect() as conn:
            cur = conn.execute(
                f"DELETE FROM books WHERE path = '' AND title IN ({placeholders})"
                " AND NOT EXISTS (SELECT 1 FROM formats f"
                "   WHERE f.book_id = books.id)",
                tuple(titles),
            )
            return cur.rowcount

    def set_hidden(self, book_id: int, hidden: bool) -> None:
        with self._connect() as conn:
            cur = conn.execute(
                "UPDATE books SET hidden = ? WHERE id = ?",
                (int(hidden), book_id),
            )
            if cur.rowcount == 0:
                raise KeyError(book_id)

    def find_by_source_id(self, source_id: str) -> Book | None:
        if not source_id:
            return None
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM books WHERE source_id = ?"
                " ORDER BY id LIMIT 1",
                (source_id,),
            ).fetchone()
            if row is None:
                return None
            return self._row_to_book(conn, row)

    # -- highlights ---------------------------------------------------------

    def add_highlight(self, book_id: int, position: str, color: str, text: str) -> int:
        created = datetime.now(timezone.utc).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO highlights (book_id, position, color, text, created)"
                " VALUES (?, ?, ?, ?, ?)",
                (book_id, position, color, text, created),
            )
            return cur.lastrowid

    def list_highlights(self, book_id: int) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, book_id, position, color, text, created"
                " FROM highlights WHERE book_id = ? ORDER BY created, id",
                (book_id,),
            ).fetchall()
            return [
                {
                    "id": row[0],
                    "book_id": row[1],
                    "position": row[2],
                    "color": row[3],
                    "text": row[4],
                    "created": row[5],
                }
                for row in rows
            ]

    def delete_highlight(self, highlight_id: int) -> None:
        with self._connect() as conn:
            conn.execute("DELETE FROM highlights WHERE id = ?", (highlight_id,))

    # -- reading position ---------------------------------------------------

    def set_reading_position(self, book_id: int, locator: str) -> None:
        updated = datetime.now(timezone.utc).isoformat()
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO reading_positions (book_id, locator, updated)"
                " VALUES (?, ?, ?)",
                (book_id, locator, updated),
            )

    def get_reading_position(self, book_id: int) -> str | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT locator FROM reading_positions WHERE book_id = ?",
                (book_id,),
            ).fetchone()
            return row[0] if row else None

    # Convenience for importer: directory holding covers etc.
    @property
    def base_dir(self) -> Path:
        if self.path == ":memory:":
            return Path.cwd()
        return Path(self.path).resolve().parent

"""Read books from a calibre library folder (``metadata.db``).

A calibre library is a directory containing ``metadata.db`` plus one
subdirectory per book holding its format files. Vellum keeps its own
catalogue, so importing records metadata and points each book at the files
inside the calibre folder; nothing in the calibre library is modified.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path

from vellum.core.db import Library
from vellum.core.models import Book

log = logging.getLogger(__name__)

# Formats the built-in reader can open, most preferred first. AZW3 is
# listed so books that only exist in that format still get a file path,
# but the Read button hides itself for unsupported formats.
_PREFERRED_FORMATS = ("epub", "pdf", "mobi", "azw3")

_BLOCK_TAGS = {
    "address", "article", "aside", "blockquote", "br", "dd", "div", "dl",
    "dt", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5",
    "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section",
    "table", "tr", "ul",
}
_SKIP_TAGS = {"script", "style"}


@dataclass
class CalibreImportResult:
    """Outcome of one calibre library import."""

    added: int = 0
    skipped: int = 0
    failed: int = 0
    first_error: str = ""


def is_calibre_library(folder: str) -> bool:
    """Return True when *folder* contains a calibre ``metadata.db``.

    This is only a cheap existence check: the database itself is opened
    and validated on the import worker thread, where snapshotting and
    SQLite errors can be reported without blocking the UI.
    """
    return (Path(folder) / "metadata.db").is_file()


def import_calibre_library(
    library: Library,
    folder: str,
    progress=None,
) -> CalibreImportResult:
    """Import every book from the calibre library in *folder*.

    Books already imported from the same calibre library (matched by the
    calibre UUID recorded in ``Book.source_id``) are skipped, so running
    an import again only adds new books. ``progress``, if given, is called
    as ``progress(done, total)`` while the import runs.
    """
    root = str(Path(folder).resolve())
    db_path = Path(root) / "metadata.db"
    if not db_path.is_file():
        raise ValueError(f"no metadata.db in {folder}")

    db = _open_database(db_path, _snapshot_root(library))
    conn = db.conn
    try:
        if not _has_table(conn, "books"):
            raise ValueError(f"{db_path} is not a calibre metadata database")
        rows, total = _book_rows(conn)
        result = CalibreImportResult()
        for done, row in enumerate(rows, start=1):
            try:
                if _import_row(conn, library, root, row):
                    result.added += 1
                else:
                    result.skipped += 1
            except Exception as exc:
                result.failed += 1
                if not result.first_error:
                    result.first_error = f"{type(exc).__name__}: {exc}"
                log.exception(
                    "failed to import calibre book %s (%s)",
                    row["title"],
                    row["id"],
                )
            if progress is not None and (done % 25 == 0 or done == total):
                progress(done, total)
        return result
    finally:
        db.close()


# -- calibre database access -------------------------------------------------


class _OpenedDatabase:
    """A calibre metadata database opened from a local snapshot."""

    def __init__(
        self,
        conn: sqlite3.Connection,
        tempdir: tempfile.TemporaryDirectory | None,
    ) -> None:
        self.conn = conn
        self._tempdir = tempdir

    def close(self) -> None:
        try:
            self.conn.close()
        finally:
            if self._tempdir is not None:
                self._tempdir.cleanup()


def _open_database(
    db_path: Path, temp_root: Path | None = None
) -> _OpenedDatabase:
    """Open a calibre database through a writable snapshot.

    Calibre libraries are commonly read-only to the app (Flatpak's
    ``home:ro`` access, document-portal mounts) and may use WAL mode.
    SQLite needs to create or write the ``-shm`` sidecar for a WAL
    database, so a direct read-only open can fail with "unable to open
    database file". Copying ``metadata.db`` and its WAL sidecars into a
    private temporary directory sidesteps locking, WAL, and FUSE quirks;
    the calibre library itself is never modified.
    """
    tempdir = tempfile.TemporaryDirectory(
        prefix="vellum-calibre-",
        dir=str(temp_root) if temp_root is not None else None,
    )
    try:
        dest = Path(tempdir.name) / "metadata.db"
        shutil.copy2(db_path, dest)
        os.chmod(dest, 0o600)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(f"{db_path}{suffix}")
            if sidecar.is_file():
                copied = Path(f"{dest}{suffix}")
                shutil.copy2(sidecar, copied)
                os.chmod(copied, 0o600)
        conn = sqlite3.connect(str(dest))
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA query_only = ON")
        return _OpenedDatabase(conn, tempdir)
    except Exception:
        tempdir.cleanup()
        raise


def _snapshot_root(library: Library) -> Path | None:
    """Prefer a disk-backed temp dir over Flatpak's RAM-backed /tmp."""
    try:
        root = library.base_dir / "tmp" / "calibre"
        root.mkdir(parents=True, exist_ok=True)
        return root
    except OSError:
        return None


def _has_table(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def _book_rows(
    conn: sqlite3.Connection,
) -> tuple[sqlite3.Cursor, int]:
    """Return a streaming cursor over calibre's books plus the row count.

    The cursor is iterated on the worker thread, so a large library is
    never materialised as a Python list.
    """
    available = _columns(conn, "books")
    wanted = ["id", "title", "sort", "isbn", "pubdate", "path", "uuid",
              "has_cover"]
    selected = [name for name in wanted if name in available]
    total = conn.execute("SELECT COUNT(*) FROM books").fetchone()[0]
    cursor = conn.execute(
        f"SELECT {', '.join(selected)} FROM books ORDER BY id"
    )
    return cursor, total


def _values(conn: sqlite3.Connection, sql: str, book_id: int) -> list[str]:
    return [str(row[0]) for row in conn.execute(sql, (book_id,)) if row[0]]


def _optional(default, func, *args):
    """Run an optional calibre metadata query, falling back to *default*.

    Calibre schema details vary between versions and some libraries have
    malformed or missing link tables. A single optional field must never
    abort the import of an otherwise readable book.
    """
    try:
        return func(*args)
    except sqlite3.Error as exc:
        log.warning("calibre metadata query failed: %s", exc)
        return default


def _author_names(conn: sqlite3.Connection, book_id: int) -> list[str]:
    if not (_has_table(conn, "authors") and _has_table(conn, "books_authors_link")):
        return []
    return _values(
        conn,
        "SELECT a.name FROM authors a"
        " JOIN books_authors_link l ON l.author = a.id"
        " WHERE l.book = ? ORDER BY l.id",
        book_id,
    )


def _tag_names(conn: sqlite3.Connection, book_id: int) -> list[str]:
    if not (_has_table(conn, "tags") and _has_table(conn, "books_tags_link")):
        return []
    return _values(
        conn,
        "SELECT t.name FROM tags t"
        " JOIN books_tags_link l ON l.tag = t.id"
        " WHERE l.book = ? ORDER BY t.name",
        book_id,
    )


def _publisher(conn: sqlite3.Connection, book_id: int) -> str:
    if not (
        _has_table(conn, "publishers")
        and _has_table(conn, "books_publishers_link")
    ):
        return ""
    names = _values(
        conn,
        "SELECT p.name FROM publishers p"
        " JOIN books_publishers_link l ON l.publisher = p.id"
        " WHERE l.book = ? ORDER BY l.id",
        book_id,
    )
    return names[0] if names else ""


def _language(conn: sqlite3.Connection, book_id: int) -> str:
    if not (
        _has_table(conn, "languages")
        and _has_table(conn, "books_languages_link")
    ):
        return ""
    codes = _values(
        conn,
        "SELECT l.lang_code FROM languages l"
        " JOIN books_languages_link bll ON bll.lang_code = l.id"
        " WHERE bll.book = ? ORDER BY bll.id",
        book_id,
    )
    return codes[0] if codes else ""


def _description(conn: sqlite3.Connection, book_id: int) -> str:
    if not _has_table(conn, "comments"):
        return ""
    rows = _values(conn, "SELECT text FROM comments WHERE book = ?", book_id)
    return _html_to_text(rows[0]) if rows else ""


def _rating(conn: sqlite3.Connection, book_id: int) -> float:
    if not (
        _has_table(conn, "ratings")
        and _has_table(conn, "books_ratings_link")
    ):
        return 0.0
    rows = _values(
        conn,
        "SELECT r.rating FROM ratings r"
        " JOIN books_ratings_link l ON l.rating = r.id"
        " WHERE l.book = ?",
        book_id,
    )
    if not rows:
        return 0.0
    try:
        return max(0.0, min(5.0, float(rows[0]) / 2.0))
    except ValueError:
        return 0.0


def _isbn(conn: sqlite3.Connection, row: sqlite3.Row) -> str:
    if _has_table(conn, "identifiers"):
        rows = _values(
            conn,
            "SELECT value FROM identifiers"
            " WHERE book = ? AND lower(type) = 'isbn' ORDER BY id",
            row["id"],
        )
        if rows:
            return rows[0].strip()
    if "isbn" not in row.keys():
        return ""
    return str(row["isbn"] or "").strip()


def _format_files(
    conn: sqlite3.Connection, root: str, book_id: int, book_path: str
) -> dict[str, str]:
    """Map lowercase format name to an existing file inside the library."""
    if not _has_table(conn, "data"):
        return {}
    if not {"book", "format", "name"} <= _columns(conn, "data"):
        return {}
    book_dir = _join_inside(root, book_path)
    if not book_dir or not os.path.isdir(book_dir):
        return {}
    try:
        entries = os.listdir(book_dir)
    except OSError:
        return {}
    by_lower = {name.lower(): name for name in entries}

    found: dict[str, str] = {}
    for row in conn.execute(
        "SELECT format, name FROM data WHERE book = ?", (book_id,)
    ):
        fmt = str(row["format"] or "").strip().lower()
        base = os.path.basename(str(row["name"] or "").strip())
        if not fmt or not base:
            continue
        filename = by_lower.get(f"{base}.{fmt}".lower())
        if filename is not None:
            found[fmt] = os.path.join(book_dir, filename)
    return found


def _cover_file(root: str, book_path: str, has_cover) -> str:
    if not has_cover:
        return ""
    book_dir = _join_inside(root, book_path)
    if not book_dir:
        return ""
    for name in ("cover.jpg", "cover.jpeg", "cover.png"):
        candidate = os.path.join(book_dir, name)
        if os.path.isfile(candidate):
            return candidate
    return ""


def _join_inside(root: str, *parts: str) -> str:
    """Join *parts* to *root*, refusing paths outside the library."""
    candidate = os.path.abspath(os.path.join(root, *parts))
    root_abs = os.path.abspath(root)
    if os.path.commonpath([root_abs, candidate]) != root_abs:
        return ""
    return candidate


def _pubdate(value) -> str:
    text = str(value or "").strip()
    match = re.match(r"(\d{4})", text)
    return match.group(1) if match else text


def _import_row(
    conn: sqlite3.Connection,
    library: Library,
    root: str,
    row: sqlite3.Row,
) -> bool:
    """Import one calibre row; return False if it is already present."""
    book_id = row["id"]
    uuid = str(row["uuid"] or "").strip() if "uuid" in row.keys() else ""
    source_id = f"calibre:{uuid}" if uuid else f"calibre:{root}:{book_id}"
    if library.find_by_source_id(source_id) is not None:
        return False

    book_path = str(row["path"] or "")
    files = _optional(
        {}, _format_files, conn, root, book_id, book_path
    )
    preferred = next(
        (files[fmt] for fmt in _PREFERRED_FORMATS if fmt in files),
        next(iter(files.values()), ""),
    )
    has_cover = row["has_cover"] if "has_cover" in row.keys() else False

    book = Book(
        title=str(row["title"] or "").strip() or "Untitled",
        sort=str(row["sort"] or "").strip() if "sort" in row.keys() else "",
        authors=_optional([], _author_names, conn, book_id),
        isbn=_optional("", _isbn, conn, row),
        publisher=_optional("", _publisher, conn, book_id),
        pubdate=_pubdate(row["pubdate"] if "pubdate" in row.keys() else ""),
        language=_optional("", _language, conn, book_id),
        description=_optional("", _description, conn, book_id),
        tags=_optional([], _tag_names, conn, book_id),
        formats=sorted(files),
        cover_path=_cover_file(root, book_path, has_cover),
        path=preferred,
        rating=_optional(0.0, _rating, conn, book_id),
        source_id=source_id,
    )
    library.add_book(book)
    return True


# -- HTML description conversion ---------------------------------------------


class _TextExtractor(HTMLParser):
    """Turn calibre's HTML comments into plain text paragraphs."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag, attrs) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
        elif tag in _BLOCK_TAGS:
            self._parts.append("\n")
        elif tag == "td":
            self._parts.append(" ")

    def handle_endtag(self, tag) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth = max(0, self._skip_depth - 1)
        elif tag in _BLOCK_TAGS:
            self._parts.append("\n")

    def handle_data(self, data) -> None:
        if self._skip_depth == 0:
            self._parts.append(data)

    def text(self) -> str:
        raw = "".join(self._parts)
        lines = [re.sub(r"\s+", " ", line).strip() for line in raw.splitlines()]
        return "\n".join(line for line in lines if line)


def _html_to_text(markup: str) -> str:
    parser = _TextExtractor()
    parser.feed(markup)
    parser.close()
    return parser.text()

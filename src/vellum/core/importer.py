"""Import ebook files into a Library."""

from __future__ import annotations

import logging
import os
import urllib.parse
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

from vellum.core.db import Library
from vellum.core.models import Book

log = logging.getLogger(__name__)

SUPPORTED = {".epub", ".mobi", ".pdf"}

_DC = "{http://purl.org/dc/elements/1.1/}"
_CONTAINS = "{urn:oasis:names:tc:opendocument:xmlns:container}"


def import_path(library: Library, path: str) -> list[int]:
    """Import a file or directory (recursively) into the library.

    Returns the ids of newly added books.
    """
    root = Path(path)
    if root.is_dir():
        files = sorted(
            p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in SUPPORTED
        )
    elif root.is_file() and root.suffix.lower() in SUPPORTED:
        files = [root]
    else:
        return []

    ids: list[int] = []
    for f in files:
        try:
            book_id = _import_file(library, f)
        except Exception:
            log.exception("failed to import %s", f)
            continue
        if book_id is not None:
            ids.append(book_id)
    return ids


def _import_file(library: Library, file: Path) -> int | None:
    ext = file.suffix.lower()
    book = Book(
        title=file.stem,
        formats=[ext.lstrip(".")],
        path=str(file),
    )
    cover: tuple[str, bytes] | None = None
    if ext == ".epub":
        try:
            meta, cover = _read_epub(file)
            for k, v in meta.items():
                setattr(book, k, v)
            if not book.title:
                book.title = file.stem
        except Exception:
            log.warning("malformed epub %s; using filename title", file)
            book = Book(title=file.stem, formats=[ext.lstrip(".")], path=str(file))
            cover = None

    book_id = library.add_book(book)
    if cover is not None:
        try:
            cover_path = _store_cover(library, book_id, cover)
            book.cover_path = cover_path
            library.update_book(book)
        except Exception:
            log.exception("failed to store cover for %s", file)
    return book_id


def _store_cover(library: Library, book_id: int, cover: tuple[str, bytes]) -> str:
    ext, data = cover
    covers_dir = library.base_dir / "covers"
    covers_dir.mkdir(parents=True, exist_ok=True)
    dest = covers_dir / f"{book_id}.{ext}"
    dest.write_bytes(data)
    return str(dest)


def _strip_isbn_prefix(text: str) -> str:
    lowered = text.lower()
    for prefix in ("urn:isbn:", "isbn:"):
        if lowered.startswith(prefix):
            return text[len(prefix):].strip()
    return text.strip()


def _read_epub(file: Path) -> tuple[dict, tuple[str, bytes] | None]:
    """Parse an epub, returning (metadata dict, (cover_ext, cover_bytes) | None)."""
    with zipfile.ZipFile(file) as zf:
        names = set(zf.namelist())
        # Locate the OPF via META-INF/container.xml.
        opf_path = None
        if "META-INF/container.xml" in names:
            container = ET.fromstring(zf.read("META-INF/container.xml"))
            for rootfile in container.iter(f"{_CONTAINS}rootfile"):
                full_path = rootfile.get("full-path")
                if full_path in names:
                    opf_path = full_path
                    break
        if opf_path is None:
            # Fallback: first .opf in the archive.
            for n in sorted(names):
                if n.lower().endswith(".opf"):
                    opf_path = n
                    break
        if opf_path is None:
            raise ValueError("no OPF found")

        opf = ET.fromstring(zf.read(opf_path))
        opf_dir = str(Path(opf_path).parent)
        if opf_dir == ".":
            opf_dir = ""

        meta: dict = {}
        for el in opf.iter():
            tag = el.tag
            if not tag.startswith(_DC):
                continue
            name = tag[len(_DC):]
            text = (el.text or "").strip()
            if name == "title" and text and "title" not in meta:
                meta["title"] = text
            elif name == "creator" and text:
                meta.setdefault("authors", []).append(text)
            elif name == "identifier" and text:
                is_isbn = "isbn" in text.lower() or any(
                    v.strip().lower() == "isbn" for v in el.attrib.values()
                )
                if is_isbn and "isbn" not in meta:
                    meta["isbn"] = _strip_isbn_prefix(text)
            elif name == "language" and text and "language" not in meta:
                meta["language"] = text
            elif name == "publisher" and text and "publisher" not in meta:
                meta["publisher"] = text
            elif name == "date" and text and "pubdate" not in meta:
                meta["pubdate"] = text
            elif name == "description" and text and "description" not in meta:
                meta["description"] = text

        cover = _find_cover(zf, opf, names, opf_dir)
        return meta, cover


def _find_cover(
    zf: zipfile.ZipFile, opf: ET.Element, names: set[str], opf_dir: str
) -> tuple[str, bytes] | None:
    href = None
    meta_cover_id = None
    items: dict[str, tuple[str, str, str]] = {}  # id -> (href, media-type, properties)
    for el in opf.iter():
        local = el.tag.rsplit("}", 1)[-1]
        if local == "item":
            items[el.get("id", "")] = (
                el.get("href", ""),
                el.get("media-type", ""),
                el.get("properties", ""),
            )
        elif local == "meta" and el.get("name") == "cover":
            meta_cover_id = el.get("content")

    # 1. EPUB3: manifest item with properties="cover-image".
    for _id, (h, mt, props) in items.items():
        if "cover-image" in props.split() and h:
            href = h
            break
    # 2. EPUB2: <meta name="cover" content="item-id">.
    if href is None and meta_cover_id and meta_cover_id in items:
        href = items[meta_cover_id][0]
    # 3. Any manifest image whose id or href mentions "cover".
    if href is None:
        for _id, (h, mt, _p) in items.items():
            if mt.startswith("image/") and ("cover" in _id.lower() or "cover" in h.lower()):
                href = h
                break
    if not href:
        return None

    decoded = urllib.parse.unquote(href)
    full = os.path.normpath(os.path.join(opf_dir, decoded)) if opf_dir else decoded
    full = full.replace("\\", "/")
    if full not in names:
        # Some EPUBs keep the encoded form as the ZIP entry name.
        full = os.path.normpath(os.path.join(opf_dir, href)) if opf_dir else href
        full = full.replace("\\", "/")
    if full not in names:
        return None
    data = zf.read(full)
    ext = Path(href).suffix.lstrip(".").lower() or "jpg"
    return ext, data

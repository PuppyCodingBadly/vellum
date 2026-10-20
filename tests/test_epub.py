"""Tests for vellum.core.epub (pure stdlib, no GTK)."""

from __future__ import annotations

import os
import zipfile

import pytest

from vellum.core.epub import EpubBook


def _make_epub(path, *, with_ncx=True):
    container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""
    opf = """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="cover.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c2"/>
    <itemref idref="c1"/>
    <itemref idref="c3"/>
  </spine>
</package>"""
    ncx = """<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel>
      <content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel>
      <content src="ch2.xhtml"/></navPoint>
    <navPoint id="n3" playOrder="3"><navLabel><text>Chapter Three</text></navLabel>
      <content src="ch3.xhtml"/></navPoint>
  </navMap>
</ncx>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("mimetype", "application/epub+zip")
        zf.writestr("META-INF/container.xml", container)
        zf.writestr("OEBPS/content.opf", opf)
        if with_ncx:
            zf.writestr("OEBPS/toc.ncx", ncx)
        for name in ("ch1", "ch2", "ch3"):
            zf.writestr(
                f"OEBPS/{name}.xhtml",
                f"<html><body><p>{name}</p></body></html>",
            )
        zf.writestr("OEBPS/cover.png", b"\x89PNG\r\n\x1a\n")
    return str(path)


def test_chapters_order_and_titles(tmp_path):
    epub = EpubBook(_make_epub(tmp_path / "book.epub"))
    chapters = epub.chapters()
    assert [href for href, _ in chapters] == ["ch2.xhtml", "ch1.xhtml", "ch3.xhtml"]
    assert [title for _, title in chapters] == [
        "Chapter Two",
        "Chapter One",
        "Chapter Three",
    ]


def test_chapters_fallback_to_stems_without_ncx(tmp_path):
    epub = EpubBook(_make_epub(tmp_path / "book.epub", with_ncx=False))
    chapters = epub.chapters()
    assert [href for href, _ in chapters] == ["ch2.xhtml", "ch1.xhtml", "ch3.xhtml"]
    assert [title for _, title in chapters] == ["ch2", "ch1", "ch3"]


def test_extract_to_idempotent(tmp_path):
    epub_path = _make_epub(tmp_path / "book.epub")
    epub = EpubBook(epub_path)
    dest = str(tmp_path / "extract")

    opf_dir = epub.extract_to(dest)
    assert opf_dir == os.path.abspath(os.path.join(dest, "OEBPS"))
    assert os.path.isfile(os.path.join(opf_dir, "content.opf"))
    assert os.path.isfile(os.path.join(opf_dir, "cover.png"))

    # Second call skips re-extraction: remove a file, it must stay removed.
    os.remove(os.path.join(opf_dir, "content.opf"))
    assert epub.extract_to(dest) == opf_dir
    assert not os.path.exists(os.path.join(opf_dir, "content.opf"))


def test_chapter_file_returns_existing_path(tmp_path):
    epub = EpubBook(_make_epub(tmp_path / "book.epub"))
    dest = str(tmp_path / "extract")
    path = epub.chapter_file(dest, 0)
    assert os.path.isfile(path)
    assert os.path.basename(path) == "ch2.xhtml"
    assert os.path.isabs(path)


def test_garbage_file_raises_value_error(tmp_path):
    bad = tmp_path / "garbage.epub"
    bad.write_bytes(b"this is not a zip at all")
    with pytest.raises(ValueError):
        EpubBook(str(bad))


def test_zip_without_container_raises_value_error(tmp_path):
    bad = tmp_path / "notepub.epub"
    with zipfile.ZipFile(bad, "w") as zf:
        zf.writestr("random.txt", "hello")
    with pytest.raises(ValueError):
        EpubBook(str(bad))

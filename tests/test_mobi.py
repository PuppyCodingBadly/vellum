"""Tests for vellum.core.mobi (pure stdlib)."""

from __future__ import annotations

import os
import struct

import pytest

from vellum.core.mobi import MobiBook

_TEXT = (
    b"<h1>Alpha</h1><p>one</p>"
    b"<mbp:pagebreak/>"
    b'<h1>Beta</h1><p>two</p><img recindex="3"/>'
)
_GIF = b"GIF89a" + b"\x01\x00\x01\x00\x80\x00\x00" + b"\x00" * 16


def _make_mobi(path):
    """Build a minimal uncompressed MOBI with 2 text records + 1 GIF image."""
    rec1 = _TEXT[: len(_TEXT) // 2]
    rec2 = _TEXT[len(_TEXT) // 2:]

    # Record 0: PalmDOC header (16 bytes) + MOBI header.
    palmdoc = struct.pack(">HHIHHHH", 1, 0, len(_TEXT), 2, 4096, 0, 0)
    mobi = bytearray(0x70)
    mobi[0:4] = b"MOBI"
    struct.pack_into(">I", mobi, 4, 0xE8)          # header length
    struct.pack_into(">I", mobi, 0x50, 3)           # first non-book index
    struct.pack_into(">I", mobi, 0x6C, 3)           # first image index
    rec0 = palmdoc + bytes(mobi)

    records = [rec0, rec1, rec2, _GIF]
    num = len(records)

    # PDB header.
    header = bytearray(78)
    name = b"TestBook"
    header[0:len(name)] = name
    header[60:68] = b"BOOKMOBI"
    struct.pack_into(">H", header, 76, num)

    table_size = 8 * num
    offset = len(header) + table_size
    table = bytearray()
    for rec in records:
        table += struct.pack(">II", offset, 0)
        offset += len(rec)

    path.write_bytes(bytes(header) + bytes(table) + b"".join(records))
    return str(path)


def test_sections_split_on_pagebreak_with_titles(tmp_path):
    mobi = MobiBook(_make_mobi(tmp_path / "book.mobi"))
    sections = mobi.sections()
    assert len(sections) == 2
    assert [title for _, title in sections] == ["Alpha", "Beta"]
    assert sections[1][0] > sections[0][0]


def test_section_html_contents_and_img_rewrite(tmp_path):
    mobi = MobiBook(_make_mobi(tmp_path / "book.mobi"))
    dest = str(tmp_path / "extract")
    mobi.extract_to(dest)

    html0 = mobi.section_html(0)
    assert "Alpha" in html0 and "one" in html0
    assert html0.startswith("<?xml")

    html1 = mobi.section_html(1)
    assert "Beta" in html1
    assert 'recindex="' not in html1
    assert os.path.join(dest, "img-3.gif") in html1


def test_extract_to_idempotent(tmp_path):
    mobi = MobiBook(_make_mobi(tmp_path / "book.mobi"))
    dest = str(tmp_path / "extract")

    out = mobi.extract_to(dest)
    assert os.path.abspath(out) == os.path.abspath(dest)
    gif_path = os.path.join(out, "img-3.gif")
    assert os.path.isfile(gif_path)
    with open(gif_path, "rb") as fh:
        assert fh.read() == _GIF

    # Second call skips re-extraction: remove the file, it must stay removed.
    os.remove(gif_path)
    assert mobi.extract_to(dest) == out
    assert not os.path.exists(gif_path)
    # Images mapping rebuilt from directory listing.
    assert "img-3.gif" not in mobi.section_html(1)


def test_garbage_file_raises_value_error(tmp_path):
    bad = tmp_path / "garbage.mobi"
    bad.write_bytes(b"this is not a mobi at all")
    with pytest.raises(ValueError):
        MobiBook(str(bad))

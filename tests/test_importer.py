"""Tests for EPUB metadata/cover extraction during import."""

from __future__ import annotations

import zipfile

from vellum.core.importer import _read_epub


def test_encoded_cover_href_is_found(tmp_path):
    path = tmp_path / "encoded-cover.epub"
    container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"""
    opf = """<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="cover" href="cover%20art.png" media-type="image/png"/>
  </manifest>
</package>"""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr("META-INF/container.xml", container)
        zf.writestr("OEBPS/content.opf", opf)
        zf.writestr("OEBPS/cover art.png", b"\x89PNG\r\n\x1a\n")

    _meta, cover = _read_epub(path)
    assert cover is not None
    assert cover[1] == b"\x89PNG\r\n\x1a\n"

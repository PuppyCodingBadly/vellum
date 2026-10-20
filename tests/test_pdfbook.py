"""Tests for vellum.core.pdfbook (Poppler GI, no GTK)."""

from __future__ import annotations

import pytest

gi = pytest.importorskip("gi")
gi.require_version("Poppler", "0.18")

from vellum.core.pdfbook import PdfBook

_PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def _make_pdf(path, texts=("Hello page one", "Hello page two")):
    """Build a minimal valid multi-page PDF with a real xref table."""
    objects = []
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join(f"{3 + i * 2} 0 R" for i in range(len(texts)))
    objects.append(
        f"<< /Type /Pages /Kids [{kids}] /Count {len(texts)} >>".encode()
    )
    font_obj = 3 + len(texts) * 2
    for i, text in enumerate(texts):
        content = (
            f"BT /F1 24 Tf 72 700 Td ({text}) Tj ET"
        ).encode()
        objects.append(
            (
                f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                f"/Resources << /Font << /F1 {font_obj} 0 R >> >> "
                f"/Contents {4 + i * 2} 0 R >>"
            ).encode()
        )
        stream = (
            b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n"
            + content + b"\nendstream"
        )
        objects.append(stream)
    objects.append(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    )

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for num, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{num} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref_start = len(out)
    size = len(objects) + 1
    out += f"xref\n0 {size}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {size} /Root 1 0 R >>\n"
        f"startxref\n{xref_start}\n%%EOF\n"
    ).encode()
    path.write_bytes(bytes(out))
    return str(path)


def test_page_count(tmp_path):
    pdf = PdfBook(_make_pdf(tmp_path / "book.pdf"))
    assert pdf.page_count() == 2


def test_render_pages_return_distinct_pngs(tmp_path):
    pdf = PdfBook(_make_pdf(tmp_path / "book.pdf"))
    page0 = pdf.render_page(0)
    page1 = pdf.render_page(1)
    assert page0.startswith(_PNG_MAGIC)
    assert page1.startswith(_PNG_MAGIC)
    assert page0 != page1


def test_title_at_fallback(tmp_path):
    pdf = PdfBook(_make_pdf(tmp_path / "book.pdf"))
    assert pdf.title_at(0)
    assert pdf.title_at(1) != pdf.title_at(0) or pdf.title_at(0) == "Page 1"


def test_garbage_file_raises_value_error(tmp_path):
    bad = tmp_path / "garbage.pdf"
    bad.write_bytes(b"this is not a pdf at all")
    with pytest.raises(ValueError):
        PdfBook(str(bad))

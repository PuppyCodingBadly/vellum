"""Tests for the cover thumbnail cache."""

from __future__ import annotations

import os
import struct

import cairo

from vellum.core.covers import thumb_path


def _make_cover(path, width=1200, height=1800):
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    ctx = cairo.Context(surface)
    ctx.set_source_rgb(0.2, 0.4, 0.8)
    ctx.paint()
    surface.write_to_png(str(path))


def _png_size(path):
    with open(path, "rb") as fh:
        header = fh.read(24)
    assert header[:8] == b"\x89PNG\r\n\x1a\n"
    assert header[12:16] == b"IHDR"
    width, height = struct.unpack(">II", header[16:24])
    return width, height


def test_thumb_created_and_scaled(tmp_path):
    cover = tmp_path / "cover.png"
    _make_cover(cover)
    thumb = thumb_path(str(tmp_path), 1, str(cover))
    assert thumb != str(cover)
    assert os.path.isfile(thumb)
    width, height = _png_size(thumb)
    assert width <= 320
    assert height <= 480
    assert (width, height) == (320, 480)


def test_thumb_contains_rendered_pixels(tmp_path):
    cover = tmp_path / "cover.png"
    _make_cover(cover)
    thumb = thumb_path(str(tmp_path), 5, str(cover))
    surface = cairo.ImageSurface.create_from_png(thumb)
    data = bytes(surface.get_data())
    stride = surface.get_stride()
    width = surface.get_width()
    height = surface.get_height()
    center = (height // 2) * stride + (width // 2) * 4
    # Premultiplied ARGB32: opaque blue-ish fill from _make_cover.
    assert data[center + 3] == 255
    assert data[center:center + 3] != b"\x00\x00\x00"


def test_thumb_paths_are_unique_across_libraries(tmp_path):
    # Book ids are per-library; the same id with a different cover must
    # not reuse another library's thumbnail.
    cover_a = tmp_path / "a.png"
    cover_b = tmp_path / "b.png"
    _make_cover(cover_a)
    _make_cover(cover_b)
    thumb_a = thumb_path(str(tmp_path), 1, str(cover_a))
    thumb_b = thumb_path(str(tmp_path), 1, str(cover_b))
    assert thumb_a != thumb_b
    assert os.path.isfile(thumb_a)
    assert os.path.isfile(thumb_b)


def test_thumb_regenerates_on_newer_source(tmp_path):
    cover = tmp_path / "cover.png"
    _make_cover(cover)
    base = 1_600_000_000
    os.utime(cover, (base, base))
    thumb = thumb_path(str(tmp_path), 2, str(cover))
    first_mtime = os.path.getmtime(thumb)
    assert first_mtime >= base

    # Same mtime or older source → cached thumb reused.
    again = thumb_path(str(tmp_path), 2, str(cover))
    assert again == thumb
    assert os.path.getmtime(thumb) == first_mtime

    # Newer source → regenerated.
    os.utime(cover, (base + 100, base + 100))
    os.utime(thumb, (base + 50, base + 50))  # ensure regeneration is visible
    regen = thumb_path(str(tmp_path), 2, str(cover))
    assert regen == thumb
    assert os.path.getmtime(thumb) >= base + 100


def test_thumb_fallback_on_garbage(tmp_path):
    cover = tmp_path / "garbage.png"
    cover.write_bytes(b"not an image at all")
    assert thumb_path(str(tmp_path), 3, str(cover)) == str(cover)
    assert thumb_path(str(tmp_path), 4, str(tmp_path / "missing.png")) == str(
        tmp_path / "missing.png"
    )

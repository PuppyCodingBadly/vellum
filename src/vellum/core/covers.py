"""Downscaled cover thumbnail cache.

Full-resolution covers are fine as JPEGs on disk, but loading them as
full-size textures for every grid card does not scale to large libraries.
Thumbnails are cached at ``<data_dir>/covers/thumbs/<book_id>.png`` and
regenerated whenever the source cover is newer.
"""

from __future__ import annotations

import os

import gi

gi.require_version("Gdk", "4.0")
from gi.repository import Gdk  # noqa: E402

import cairo  # noqa: E402

THUMB_MAX_WIDTH = 320
THUMB_MAX_HEIGHT = 480


def thumb_path(data_dir: str, book_id: int, cover_path: str) -> str:
    """Return a cached ≤320x480 PNG thumbnail for ``cover_path``.

    Regenerates the thumbnail if missing or older than the source cover.
    On any failure the original ``cover_path`` is returned instead.
    """
    try:
        if not cover_path or not os.path.isfile(cover_path):
            return cover_path
        thumbs_dir = os.path.join(data_dir, "covers", "thumbs")
        thumb = os.path.join(thumbs_dir, f"{book_id}.png")
        try:
            if os.path.getmtime(thumb) >= os.path.getmtime(cover_path):
                return thumb
        except OSError:
            pass

        texture = Gdk.Texture.new_from_filename(cover_path)
        src_w = texture.get_width()
        src_h = texture.get_height()
        if src_w <= 0 or src_h <= 0:
            return cover_path
        scale = min(THUMB_MAX_WIDTH / src_w, THUMB_MAX_HEIGHT / src_h, 1.0)
        dst_w = max(1, round(src_w * scale))
        dst_h = max(1, round(src_h * scale))

        # Download as BGRA premultiplied (== native-endian ARGB32).
        stride = src_w * 4
        buf = bytearray(stride * src_h)
        texture.download(buf, stride)  # GDK_MEMORY_DEFAULT format
        src = cairo.ImageSurface.create_for_data(
            buf, cairo.FORMAT_ARGB32, src_w, src_h, stride
        )
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, dst_w, dst_h)
        ctx = cairo.Context(surface)
        ctx.scale(dst_w / src_w, dst_h / src_h)
        ctx.set_source_surface(src, 0, 0)
        ctx.get_source().set_filter(cairo.FILTER_GOOD)
        ctx.paint()

        os.makedirs(thumbs_dir, exist_ok=True)
        surface.write_to_png(thumb)
        return thumb
    except Exception:
        return cover_path

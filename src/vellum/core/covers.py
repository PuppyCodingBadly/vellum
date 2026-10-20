"""Downscaled cover thumbnail cache.

Full-resolution covers are fine as JPEGs on disk, but loading them as
full-size textures for every grid card does not scale to large libraries.
Thumbnails are cached at ``<data_dir>/covers/thumbs/<book_id>.png`` and
regenerated whenever the source cover is newer.

Thumbnails are generated off the GTK main thread, so this module uses
GdkPixbuf only: creating Gdk.Textures or touching GTK/GDK display objects
from a worker thread is not safe and has crashed compositors on some
drivers.
"""

from __future__ import annotations

import hashlib
import os

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

THUMB_MAX_WIDTH = 320
THUMB_MAX_HEIGHT = 480
MAX_COVER_BYTES = 25 * 1024 * 1024
MAX_COVER_PIXELS = 80_000_000


def thumb_cache_path(data_dir: str, book_id: int, cover_path: str) -> str:
    """Return the thumbnail path for a book's cover without generating it.

    Book ids are only unique within a library, so the source path is
    hashed into the filename; two libraries can then never share a
    thumbnail for different books with the same id.
    """
    digest = hashlib.sha1(
        os.path.realpath(cover_path).encode("utf-8", "surrogateescape")
    ).hexdigest()[:12]
    return os.path.join(
        data_dir, "covers", "thumbs", f"{book_id}-{digest}.png"
    )


def thumb_path(data_dir: str, book_id: int, cover_path: str) -> str:
    """Return a cached ≤320x480 PNG thumbnail for ``cover_path``.

    Regenerates the thumbnail if missing or older than the source cover.
    Safe to call from a worker thread. On any failure the original
    ``cover_path`` is returned instead.
    """
    try:
        if not cover_path or not os.path.isfile(cover_path):
            return cover_path
        thumbs_dir = os.path.join(data_dir, "covers", "thumbs")
        thumb = thumb_cache_path(data_dir, book_id, cover_path)
        try:
            if os.path.getmtime(thumb) >= os.path.getmtime(cover_path):
                return thumb
        except OSError:
            pass

        try:
            if os.path.getsize(cover_path) > MAX_COVER_BYTES:
                return cover_path
            info = GdkPixbuf.Pixbuf.get_file_info(cover_path)
            _fmt, width, height = info
        except Exception:
            return cover_path
        if not width or not height or width * height > MAX_COVER_PIXELS:
            return cover_path

        pixbuf = GdkPixbuf.Pixbuf.new_from_file(cover_path)
        src_w = pixbuf.get_width()
        src_h = pixbuf.get_height()
        if src_w <= 0 or src_h <= 0:
            return cover_path
        scale = min(THUMB_MAX_WIDTH / src_w, THUMB_MAX_HEIGHT / src_h, 1.0)
        dst_w = max(1, round(src_w * scale))
        dst_h = max(1, round(src_h * scale))
        scaled = pixbuf.scale_simple(
            dst_w, dst_h, GdkPixbuf.InterpType.BILINEAR
        )
        if scaled is None:
            return cover_path

        os.makedirs(thumbs_dir, exist_ok=True)
        scaled.savev(thumb, "png", [], [])
        return thumb
    except Exception:
        return cover_path

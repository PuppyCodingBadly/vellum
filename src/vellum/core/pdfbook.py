"""PDF reading via Poppler GI bindings (no Gtk/Adw/WebKit imports)."""

from __future__ import annotations

import io

import cairo
import gi

gi.require_version("Poppler", "0.18")
from gi.repository import GLib, Poppler

DEFAULT_SCALE = 1.75


class PdfBook:
    """Open a PDF and render pages to PNG bytes."""

    def __init__(self, path: str):
        try:
            uri = GLib.filename_to_uri(path)
            self._doc = Poppler.Document.new_from_file(uri)
        except Exception as exc:  # GLib.Error and friends
            raise ValueError(f"not a readable PDF: {path}") from exc
        if self._doc is None or self._doc.get_n_pages() < 1:
            raise ValueError(f"not a readable PDF: {path}")

    def page_count(self) -> int:
        return self._doc.get_n_pages()

    def _page(self, index: int) -> Poppler.Page:
        if not 0 <= index < self.page_count():
            raise IndexError(f"page index out of range: {index}")
        return self._doc.get_page(index)

    def render_page(self, index: int, scale: float = DEFAULT_SCALE) -> bytes:
        """Render *index* to PNG bytes at *scale* (1.0 = PDF points)."""
        page = self._page(index)
        width, height = page.get_size()
        surface = cairo.ImageSurface(
            cairo.FORMAT_ARGB32,
            max(1, int(width * scale)),
            max(1, int(height * scale)),
        )
        ctx = cairo.Context(surface)
        ctx.scale(scale, scale)
        page.render(ctx)
        surface.flush()
        buf = io.BytesIO()
        surface.write_to_png(buf)
        return buf.getvalue()

    def title_at(self, index: int) -> str:
        page = self._page(index)
        label = page.get_label()
        return label if label else f"Page {index + 1}"

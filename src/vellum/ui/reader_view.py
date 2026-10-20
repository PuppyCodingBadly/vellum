"""Reader page: EPUB chapters, PDF pages, MOBI sections with navigation."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("WebKit", "6.0")
from gi.repository import Adw, Gdk, GLib, Gtk, Pango, WebKit

from vellum.core.epub import EpubBook
from vellum.core.mobi import MobiBook
from vellum.core.models import Book
from vellum.core.pdfbook import PdfBook

_CSS_LIGHT = (
    "body { max-width: 46em; margin: 1em auto; padding: 0 1em;"
    " line-height: 1.15; background: #ffffff; color: #1a1a1a; }"
    " img { max-width: 100%; height: auto; }"
)
_CSS_DARK = (
    "body { max-width: 46em; margin: 1em auto; padding: 0 1em;"
    " line-height: 1.15; background: #1e1e1e; color: #e8e8e8; }"
    " img { max-width: 100%; height: auto; }"
    " a { color: #8ab4f8; }"
)

_INJECT_JS = (
    "(function(){"
    "var s = document.getElementById('vellum-reader-css');"
    "if (!s) { s = document.createElement('style');"
    "s.id = 'vellum-reader-css'; document.head.appendChild(s); }"
    "s.textContent = %s;"
    "window.scrollTo(0, 0);"
    "})();"
)

_ANIMATION_DURATION_MS = 200
_MIN_ZOOM = 1.0
_MAX_ZOOM = 3.0
_ZOOM_STEP = 0.25


class ReaderPage(Gtk.Box):
    """Render books (epub/pdf/mobi) with prev/next navigation."""

    def __init__(self, book: Book, data_dir: str):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._book = book
        self._data_dir = data_dir
        self._kind = self._primary_format(book)
        self._epub: EpubBook | None = None
        self._pdf: PdfBook | None = None
        self._mobi: MobiBook | None = None
        self._items: list[tuple[str, str]] = []
        self._index = 0
        self._scale = 1.75
        self._content_serial = 0

        key = book.id or hashlib.sha1(book.path.encode()).hexdigest()[:16]
        self._cache_dir = os.path.join(
            GLib.get_user_cache_dir(), "vellum", "reader", str(key)
        )

        try:
            self._open()
        except (ValueError, OSError):
            self._show_error()
            return

        self._build_reader()
        self._show_item(0, 0)

    # -- setup ----------------------------------------------------------------

    @staticmethod
    def _primary_format(book: Book) -> str:
        formats = {f.lower() for f in (book.formats or [])}
        for fmt in ("epub", "pdf", "mobi", "azw3"):
            if fmt in formats:
                return fmt
        return "epub"

    def _open(self) -> None:
        if self._kind == "pdf":
            self._pdf = PdfBook(self._book.path)
            count = self._pdf.page_count()
            self._items = [("", self._pdf.title_at(i)) for i in range(count)]
        elif self._kind in ("mobi", "azw3"):
            self._mobi = MobiBook(self._book.path)
            sections = self._mobi.sections()
            if not sections:
                raise ValueError("mobi has no readable sections")
            self._mobi.extract_to(os.path.join(self._cache_dir, "mobi"))
            self._items = [("", title) for _, title in sections]
        else:
            self._kind = "epub"
            self._epub = EpubBook(self._book.path)
            chapters = self._epub.chapters()
            if not chapters:
                raise ValueError("epub has no readable chapters")
            self._epub.extract_to(self._cache_dir)
            self._items = chapters

    # -- UI -------------------------------------------------------------------

    def _show_error(self) -> None:
        status = Adw.StatusPage(
            title="Cannot Open Book",
            description="This book file is not valid or is corrupted.",
            icon_name="dialog-error-symbolic",
            vexpand=True,
        )
        self.append(status)

    def _build_reader(self) -> None:
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        header.set_margin_top(6)
        header.set_margin_bottom(6)
        header.set_margin_start(6)
        header.set_margin_end(6)
        self.append(header)

        self._prev_button = Gtk.Button(icon_name="go-previous-symbolic")
        self._prev_button.set_tooltip_text("Previous")
        self._prev_button.connect("clicked", lambda _b: self.prev_chapter())
        header.append(self._prev_button)

        self._title_label = Gtk.Label(
            ellipsize=Pango.EllipsizeMode.END, hexpand=True, xalign=0.5
        )
        self._title_label.add_css_class("heading")
        header.append(self._title_label)

        self._counter_label = Gtk.Label()
        self._counter_label.add_css_class("dim-label")
        header.append(self._counter_label)

        self._next_button = Gtk.Button(icon_name="go-next-symbolic")
        self._next_button.set_tooltip_text("Next")
        self._next_button.connect("clicked", lambda _b: self.next_chapter())
        header.append(self._next_button)

        self._stack = Gtk.Stack(vexpand=True, hexpand=True)
        self.append(self._stack)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key_pressed)
        self.add_controller(keys)

    # -- content builders -------------------------------------------------------

    def _new_webview(self, inject_css: bool) -> WebKit.WebView:
        webview = WebKit.WebView(vexpand=True, hexpand=True)
        if inject_css:
            webview.connect("load-changed", self._on_load_changed)
        return webview

    def _build_content(self, index: int) -> Gtk.Widget:
        if self._kind == "pdf":
            data = self._pdf.render_page(index, self._scale)
            texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))
            picture = Gtk.Picture.new_for_paintable(texture)
            picture.set_content_fit(Gtk.ContentFit.CONTAIN)
            picture.set_can_shrink(True)
            picture.set_vexpand(True)
            picture.set_hexpand(True)
            return picture
        if self._kind in ("mobi", "azw3"):
            html = self._mobi.section_html(index)
            section_path = os.path.join(
                self._cache_dir, "mobi", f"section-{index}.xhtml"
            )
            with open(section_path, "w", encoding="utf-8") as fh:
                fh.write(html)
            webview = self._new_webview(inject_css=True)
            webview.load_uri(Path(section_path).as_uri())
            return webview
        webview = self._new_webview(inject_css=True)
        chapter_path = Path(self._epub.chapter_file(self._cache_dir, index))
        webview.load_uri(chapter_path.as_uri())
        return webview

    # -- navigation -------------------------------------------------------------

    def prev_chapter(self) -> None:
        if self._index > 0:
            self._show_item(self._index - 1, -1)

    def next_chapter(self) -> None:
        if self._index < len(self._items) - 1:
            self._show_item(self._index + 1, 1)

    def _animation_enabled(self) -> bool:
        try:
            with open(os.path.join(self._data_dir, "config.json"),
                      encoding="utf-8") as fh:
                config = json.load(fh)
            return bool(config.get("reader_animation", True))
        except (OSError, ValueError):
            return True

    def _swap_content(self, widget: Gtk.Widget, direction: int) -> None:
        old = self._stack.get_visible_child()
        if self._animation_enabled():
            if direction > 0:
                transition = Gtk.StackTransitionType.SLIDE_LEFT
            elif direction < 0:
                transition = Gtk.StackTransitionType.SLIDE_RIGHT
            else:
                transition = Gtk.StackTransitionType.NONE
        else:
            transition = Gtk.StackTransitionType.NONE
        self._stack.set_transition_type(transition)
        self._stack.set_transition_duration(_ANIMATION_DURATION_MS)
        name = f"page-{self._content_serial}"
        self._content_serial += 1
        self._stack.add_named(widget, name)
        self._stack.set_visible_child_name(name)
        if old is not None and old is not widget:
            def _drop_old() -> bool:
                if old.get_parent() is not None:
                    self._stack.remove(old)
                return False
            GLib.timeout_add(_ANIMATION_DURATION_MS + 50, _drop_old)

    def _show_item(self, index: int, direction: int) -> None:
        self._index = index
        try:
            content = self._build_content(index)
        except (ValueError, OSError, IndexError):
            if not self._stack.get_first_child():
                self._show_error()
            return
        self._swap_content(content, direction)
        _, title = self._items[index]
        self._title_label.set_label(title)
        prefix = {"pdf": "Page", "mobi": "Section", "azw3": "Section"}.get(
            self._kind, ""
        )
        counter = f"{index + 1} / {len(self._items)}"
        self._counter_label.set_label(
            f"{prefix} {counter}" if prefix else counter
        )
        self._prev_button.set_sensitive(index > 0)
        self._next_button.set_sensitive(index < len(self._items) - 1)

    # -- webview ----------------------------------------------------------------

    def _on_load_changed(self, webview: WebKit.WebView,
                         event: WebKit.LoadEvent) -> None:
        if event != WebKit.LoadEvent.FINISHED:
            return
        dark = Adw.StyleManager.get_default().get_dark()
        css = json.dumps(_CSS_DARK if dark else _CSS_LIGHT)
        webview.evaluate_javascript(_INJECT_JS % css, -1, None, None, None)

    def _on_key_pressed(self, _controller, keyval: int, _keycode: int,
                        state: Gdk.ModifierType) -> bool:
        if keyval == Gdk.KEY_Left:
            self.prev_chapter()
            return True
        if keyval == Gdk.KEY_Right:
            self.next_chapter()
            return True
        if (self._kind == "pdf"
                and state & Gdk.ModifierType.CONTROL_MASK):
            if keyval in (Gdk.KEY_plus, Gdk.KEY_equal):
                return self._zoom(_ZOOM_STEP)
            if keyval == Gdk.KEY_minus:
                return self._zoom(-_ZOOM_STEP)
        return False

    def _zoom(self, delta: float) -> bool:
        new_scale = min(_MAX_ZOOM, max(_MIN_ZOOM, self._scale + delta))
        if new_scale == self._scale:
            return True
        self._scale = new_scale
        self._show_item(self._index, 0)
        return True

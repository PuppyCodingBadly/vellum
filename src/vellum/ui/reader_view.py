"""EPUB reader page with prev/next chapter navigation."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("WebKit", "6.0")
from gi.repository import Adw, Gdk, GLib, Gtk, Pango, WebKit

from vellum.core.epub import EpubBook
from vellum.core.models import Book

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


class ReaderPage(Gtk.Box):
    """Render epub chapters in a WebKit view with chapter navigation."""

    def __init__(self, book: Book, data_dir: str):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._book = book
        self._data_dir = data_dir
        self._epub: EpubBook | None = None
        self._chapters: list[tuple[str, str]] = []
        self._index = 0
        self._extract_dir = ""

        key = book.id or hashlib.sha1(book.path.encode()).hexdigest()[:16]
        self._cache_dir = os.path.join(
            GLib.get_user_cache_dir(), "vellum", "reader", str(key)
        )

        try:
            self._epub = EpubBook(book.path)
            self._chapters = self._epub.chapters()
            if not self._chapters:
                raise ValueError("epub has no readable chapters")
            self._extract_dir = self._epub.extract_to(self._cache_dir)
        except (ValueError, OSError):
            self._show_error()
            return

        self._build_reader()
        self._load_chapter(0)

    # -- UI -------------------------------------------------------------------

    def _show_error(self) -> None:
        status = Adw.StatusPage(
            title="Cannot Open Book",
            description="This book is not a valid EPUB file or is corrupted.",
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
        self._prev_button.set_tooltip_text("Previous chapter")
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
        self._next_button.set_tooltip_text("Next chapter")
        self._next_button.connect("clicked", lambda _b: self.next_chapter())
        header.append(self._next_button)

        self._webview = WebKit.WebView(vexpand=True, hexpand=True)
        self._webview.connect("load-changed", self._on_load_changed)
        self.append(self._webview)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key_pressed)
        self.add_controller(keys)

    # -- navigation -------------------------------------------------------------

    def prev_chapter(self) -> None:
        if self._index > 0:
            self._load_chapter(self._index - 1)

    def next_chapter(self) -> None:
        if self._index < len(self._chapters) - 1:
            self._load_chapter(self._index + 1)

    def _load_chapter(self, index: int) -> None:
        self._index = index
        href, title = self._chapters[index]
        chapter_path = Path(self._epub.chapter_file(self._cache_dir, index))
        self._webview.load_uri(chapter_path.as_uri())
        self._title_label.set_label(title)
        self._counter_label.set_label(f"{index + 1} / {len(self._chapters)}")
        self._prev_button.set_sensitive(index > 0)
        self._next_button.set_sensitive(index < len(self._chapters) - 1)

    # -- webview ----------------------------------------------------------------

    def _on_load_changed(self, webview: WebKit.WebView,
                         event: WebKit.LoadEvent) -> None:
        if event != WebKit.LoadEvent.FINISHED:
            return
        dark = Adw.StyleManager.get_default().get_dark()
        import json
        css = json.dumps(_CSS_DARK if dark else _CSS_LIGHT)
        webview.evaluate_javascript(_INJECT_JS % css, -1, None, None, None)

    def _on_key_pressed(self, _controller, keyval: int, _keycode: int,
                        _state: Gdk.ModifierType) -> bool:
        if keyval == Gdk.KEY_Left:
            self.prev_chapter()
            return True
        if keyval == Gdk.KEY_Right:
            self.next_chapter()
            return True
        return False

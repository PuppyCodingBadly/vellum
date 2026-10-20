"""Reader page: EPUB chapters, PDF pages, MOBI sections with navigation."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Graphene", "1.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Adw, Gdk, GLib, Graphene, Gtk, Pango, WebKit

from vellum.core.epub import EpubBook
from vellum.core.gestures import swipe_direction
from vellum.core.mobi import MobiBook
from vellum.core.models import Book

if TYPE_CHECKING:
    from vellum.core.pdfbook import PdfBook

logger = logging.getLogger(__name__)

_THEMES = {
    "light": ("#ffffff", "#1a1a1a", None),
    "sepia": ("#f4ecd8", "#5b4636", None),
    "dark": ("#1e1e1e", "#e8e8e8", "#8ab4f8"),
}

_HIGHLIGHT_COLORS = ("yellow", "green", "pink")

# Injected once per page: selection + scroll reporting, highlight
# (un)wrapping and scroll-to-offset helpers. Offsets are character
# offsets within document.body.textContent; wrapping in spans does not
# change textContent, so stored offsets stay valid.
_BRIDGE_JS = r"""
(function(){
if (window.__vellumInstalled) return;
window.__vellumInstalled = true;

function bodyEl() {
  return document.body
      || document.getElementsByTagName('body')[0]
      || document.documentElement;
}

function offsetsOf(range) {
  var walker = document.createTreeWalker(bodyEl(),
      NodeFilter.SHOW_TEXT, null);
  var node, pos = 0, start = -1, end = -1;
  while ((node = walker.nextNode())) {
    var len = node.nodeValue.length;
    if (node === range.startContainer) start = pos + range.startOffset;
    if (node === range.endContainer) end = pos + range.endOffset;
    if (start >= 0 && end >= 0) break;
    pos += len;
  }
  if (start < 0 || end < 0) return null;
  return {start: start, end: end};
}

document.addEventListener('selectionchange', function(){
  var sel = window.getSelection();
  var payload = {type: 'selection', text: '', start: 0, end: 0};
  if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
    var info = offsetsOf(sel.getRangeAt(0));
    if (info) {
      payload.text = sel.toString();
      payload.start = info.start;
      payload.end = info.end;
    }
  }
  window.webkit.messageHandlers.vellum.postMessage(payload);
});

function postScroll() {
  var max = document.documentElement.scrollHeight - window.innerHeight;
  var frac = max > 0 ? window.scrollY / max : 0;
  window.webkit.messageHandlers.vellum.postMessage(
      {type: 'scroll', fraction: frac});
}
var lastScroll = 0, scrollTimer = null;
window.addEventListener('scroll', function(){
  var now = Date.now();
  if (now - lastScroll >= 1000) { lastScroll = now; postScroll(); }
  if (scrollTimer) clearTimeout(scrollTimer);
  scrollTimer = setTimeout(function(){ lastScroll = Date.now();
    postScroll(); }, 1000);
});

var colors = {yellow: '#f2d94e', green: '#a8e6a3', pink: '#f7b6d2'};

window.__vellumHighlight = function(start, end, color, hlId){
  var walker = document.createTreeWalker(bodyEl(),
      NodeFilter.SHOW_TEXT, null);
  var node, pos = 0, sNode = null, sOff = 0, eNode = null, eOff = 0;
  while ((node = walker.nextNode())) {
    var len = node.nodeValue.length;
    if (sNode === null && pos + len >= start) {
      sNode = node; sOff = start - pos;
    }
    if (pos + len >= end) { eNode = node; eOff = end - pos; break; }
    pos += len;
  }
  if (!sNode || !eNode) return false;
  try {
    var range = document.createRange();
    range.setStart(sNode, sOff);
    range.setEnd(eNode, eOff);
    var span = document.createElement('span');
    span.className = 'vellum-hl';
    span.setAttribute('data-vellum-hl', String(hlId));
    span.style.backgroundColor = colors[color] || color;
    span.appendChild(range.extractContents());
    range.insertNode(span);
    return true;
  } catch (e) { return false; }
};

window.__vellumUnhighlight = function(hlId){
  var spans = document.querySelectorAll(
      'span.vellum-hl[data-vellum-hl="' + String(hlId) + '"]');
  for (var i = 0; i < spans.length; i++) {
    var sp = spans[i], parent = sp.parentNode;
    while (sp.firstChild) parent.insertBefore(sp.firstChild, sp);
    parent.removeChild(sp);
    parent.normalize();
  }
  return true;
};

window.__vellumJump = function(start){
  var walker = document.createTreeWalker(bodyEl(),
      NodeFilter.SHOW_TEXT, null);
  var node, pos = 0;
  while ((node = walker.nextNode())) {
    var len = node.nodeValue.length;
    if (pos + len >= start) {
      try {
        var range = document.createRange();
        range.setStart(node, Math.min(start - pos, len));
        range.collapse(true);
        var rect = range.getBoundingClientRect();
        window.scrollTo(0, window.scrollY + rect.top -
                        window.innerHeight / 3);
      } catch (e) {}
      return true;
    }
    pos += len;
  }
  return false;
};
})();
"""

_INJECT_CSS_JS = (
    "(function(){"
    "var s = document.getElementById('vellum-reader-css');"
    "if (!s) { s = document.createElement('style');"
    "s.id = 'vellum-reader-css';"
    "var h = document.head || document.documentElement;"
    "if (h) { h.appendChild(s); } }"
    "s.textContent = %s;"
    "})();"
)

_SCROLL_TO_JS = (
    "(function(){var m=document.documentElement.scrollHeight"
    "-window.innerHeight;window.scrollTo(0,m*%f);})();"
)

_ANIMATION_DURATION_MS = 200
_SELECTION_DEBOUNCE_MS = 350
_SCROLL_SAVE_MIN_INTERVAL = 1.0
_PDF_CACHE_SIZE = 3
_MIN_ZOOM = 1.0
_MAX_ZOOM = 3.0
_ZOOM_STEP = 0.25
_MIN_FONT_SCALE = 0.8
_MAX_FONT_SCALE = 1.6
_FONT_SCALE_STEP = 0.1
_BASE_PDF_SCALE = 1.75

_READER_CSS = """
.vellum-hl-dot { border-radius: 9px; }
.hl-dot-yellow { background: #f2d94e; }
.hl-dot-green { background: #a8e6a3; }
.hl-dot-pink { background: #f7b6d2; }
progressbar.vellum-progress trough,
progressbar.vellum-progress trough progress { min-height: 4px; }
"""

_css_installed = False


def _ensure_reader_css() -> None:
    global _css_installed
    if _css_installed:
        return
    display = Gdk.Display.get_default()
    if display is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_data(_READER_CSS.encode("utf-8"))
    Gtk.StyleContext.add_provider_for_display(
        display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
    )
    _css_installed = True


class ReaderPage(Gtk.Box):
    """Render books (epub/pdf/mobi) with prev/next navigation."""

    def __init__(self, book: Book, data_dir: str, library=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._book = book
        self._data_dir = data_dir
        self._library = library
        self._kind = self._primary_format(book)
        self._epub: EpubBook | None = None
        self._pdf: PdfBook | None = None
        self._mobi: MobiBook | None = None
        self._items: list[tuple[str, str]] = []
        self._index = 0
        self._scale = _BASE_PDF_SCALE
        self._content_serial = 0
        self._webview: WebKit.WebView | None = None
        # Pool of recycled webviews (epub/mobi), capped at two; created
        # lazily by _pool_webview(). self._webview is the visible one.
        self._webviews: list[WebKit.WebView] = []
        # PDF render cache {index: png_bytes}, LRU, capped at
        # _PDF_CACHE_SIZE. Mutated only on the main thread.
        self._pdf_cache: dict[int, bytes] = {}
        self._pdf_lock = threading.Lock()
        self._pdf_render_serial = 0
        self._pdf_displayed_paintable: Gdk.Paintable | None = None
        self._last_position_write = 0.0
        self._position_flush_source = 0
        self._pending_selection: dict | None = None
        self._selection_popover: Gtk.Popover | None = None
        self._selection_source = 0
        self._pending_scroll: float | None = None
        self._pending_jump: int | None = None
        self._last_fraction = 0.0

        _ensure_reader_css()
        config = self._read_config()
        try:
            self._font_scale = min(
                _MAX_FONT_SCALE,
                max(_MIN_FONT_SCALE,
                    float(config.get("reader_font_scale", 1.0))),
            )
        except (TypeError, ValueError):
            self._font_scale = 1.0
        self._theme = config.get("reader_theme", "follow")
        if self._theme not in ("follow", "light", "sepia", "dark"):
            self._theme = "follow"

        # Book ids are per-library, and a file can be replaced; include
        # the path and source signature so cached extractions never
        # leak between libraries or stale versions.
        try:
            st = os.stat(book.path)
            signature = f"{st.st_mtime_ns}:{st.st_size}"
        except OSError:
            signature = "0:0"
        key = hashlib.sha1(
            f"{book.id}:{book.path}:{signature}".encode(
                "utf-8", "surrogateescape"
            )
        ).hexdigest()[:16]
        self._cache_dir = os.path.join(
            GLib.get_user_cache_dir(), "vellum", "reader", key
        )

        try:
            self._open()
        except (ValueError, OSError) as exc:
            self._show_error(str(exc))
            return

        self._build_reader()
        index, fraction = self._restore_position()
        if self._kind == "pdf":
            self._last_fraction = 0.0
        elif fraction > 0.0:
            self._pending_scroll = fraction
            self._last_fraction = fraction
        self._show_item(index, 0)

        style_manager = Adw.StyleManager.get_default()
        self._style_handler = style_manager.connect(
            "notify::dark", self._on_dark_changed
        )

        def _disconnect_style(*_args) -> None:
            handler = getattr(self, "_style_handler", 0)
            if handler:
                style_manager.disconnect(handler)
                self._style_handler = 0

        self.connect("unrealize", _disconnect_style)
        self.connect("unrealize", self._flush_position_on_unrealize)

    # -- setup ----------------------------------------------------------------

    @staticmethod
    def _primary_format(book: Book) -> str:
        formats = {f.lower() for f in (book.formats or [])}
        for fmt in ("epub", "pdf", "mobi"):
            if fmt in formats:
                return fmt
        return "epub"

    @property
    def _is_web(self) -> bool:
        return self._kind in ("epub", "mobi")

    def _open(self) -> None:
        if self._kind == "pdf":
            try:
                from vellum.core.pdfbook import PdfBook
            except (ImportError, ValueError) as exc:
                raise ValueError(
                    "PDF support requires the Poppler GI bindings"
                ) from exc
            self._pdf = PdfBook(self._book.path)
            count = self._pdf.page_count()
            self._items = [("", self._pdf.title_at(i)) for i in range(count)]
        elif self._kind == "mobi":
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

    # -- config ----------------------------------------------------------------

    def _read_config(self) -> dict:
        try:
            with open(os.path.join(self._data_dir, "config.json"),
                      encoding="utf-8") as fh:
                data = json.load(fh)
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write_config(self, key: str, value) -> None:
        config = self._read_config()
        config[key] = value
        path = os.path.join(self._data_dir, "config.json")
        try:
            os.makedirs(self._data_dir, exist_ok=True)
            tmp_path = path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as fh:
                json.dump(config, fh, indent=2)
            os.replace(tmp_path, path)
        except OSError as exc:
            logger.warning("Could not write config %s: %s", path, exc)

    # -- UI -------------------------------------------------------------------

    def _show_error(self, detail: str = "") -> None:
        status = Adw.StatusPage(
            title="Cannot Open Book",
            description=detail or "This book file is not valid or is corrupted.",
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

        self._next_button = Gtk.Button(icon_name="go-next-symbolic")
        self._next_button.set_tooltip_text("Next")
        self._next_button.connect("clicked", lambda _b: self.next_chapter())
        header.append(self._next_button)

        self._title_label = Gtk.Label(
            ellipsize=Pango.EllipsizeMode.END, hexpand=True, xalign=0.5
        )
        self._title_label.add_css_class("heading")
        header.append(self._title_label)

        self._counter_label = Gtk.Label()
        self._counter_label.add_css_class("dim-label")
        header.append(self._counter_label)

        self._font_down = Gtk.Button(icon_name="zoom-out-symbolic")
        self._font_down.set_tooltip_text("Decrease font size")
        self._font_down.connect(
            "clicked", lambda _b: self._change_font_scale(-_FONT_SCALE_STEP)
        )
        header.append(self._font_down)

        self._font_up = Gtk.Button(icon_name="zoom-in-symbolic")
        self._font_up.set_tooltip_text("Increase font size")
        self._font_up.connect(
            "clicked", lambda _b: self._change_font_scale(_FONT_SCALE_STEP)
        )
        header.append(self._font_up)

        toc_popover = Gtk.Popover()
        toc_popover.connect("show", lambda _p: self._refresh_toc())
        self._toc_box = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL, spacing=0
        )
        toc_scroll = Gtk.ScrolledWindow(
            hscrollbar_policy=Gtk.PolicyType.NEVER,
            propagate_natural_height=True,
            max_content_height=400,
        )
        toc_scroll.set_child(self._toc_box)
        toc_popover.set_child(toc_scroll)
        self._toc_popover = toc_popover
        toc_button = Gtk.MenuButton(label="Chapters", popover=toc_popover)
        toc_button.set_tooltip_text("Table of contents")
        header.append(toc_button)

        if self._is_web:
            hl_popover = Gtk.Popover()
            hl_popover.connect("show", lambda _p: self._refresh_highlights())
            self._hl_box = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL, spacing=6
            )
            self._hl_box.set_margin_top(6)
            self._hl_box.set_margin_bottom(6)
            self._hl_box.set_margin_start(6)
            self._hl_box.set_margin_end(6)
            hl_scroll = Gtk.ScrolledWindow(
                hscrollbar_policy=Gtk.PolicyType.NEVER,
                propagate_natural_height=True,
                propagate_natural_width=True,
                max_content_height=400,
                max_content_width=380,
            )
            hl_scroll.set_child(self._hl_box)
            hl_popover.set_child(hl_scroll)
            self._hl_popover = hl_popover
            hl_button = Gtk.MenuButton(
                icon_name="view-list-symbolic", popover=hl_popover
            )
            hl_button.set_tooltip_text("Highlights")
            header.append(hl_button)
        else:
            self._hl_box = None
            self._hl_popover = None

        theme_popover = self._build_theme_popover()
        theme_button = Gtk.MenuButton(
            icon_name="applications-graphics-symbolic", popover=theme_popover
        )
        theme_button.set_tooltip_text("Reader theme")
        header.append(theme_button)

        fullscreen_button = Gtk.Button(icon_name="view-fullscreen-symbolic")
        fullscreen_button.set_tooltip_text("Toggle fullscreen (F11)")
        fullscreen_button.connect(
            "clicked", lambda _b: self._toggle_fullscreen()
        )
        header.append(fullscreen_button)

        self._stack = Gtk.Stack(vexpand=True, hexpand=True)
        self.append(self._stack)

        # Touch page turning. Attached only to the content stack, never
        # the window or navigation, so it cannot interact with shell
        # gestures. Horizontal swipes turn a page/chapter; vertical
        # scrolling is left to the content widget.
        self._swipe = Gtk.GestureSwipe()
        self._swipe.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        self._swipe.connect("swipe", self._on_swipe)
        self._stack.add_controller(self._swipe)

        self._progress = Gtk.ProgressBar(show_text=False)
        self._progress.add_css_class("vellum-progress")
        self._progress.set_valign(Gtk.Align.END)
        self.append(self._progress)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key_pressed)
        self.add_controller(keys)

    def _build_theme_popover(self) -> Gtk.Popover:
        popover = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(6)
        box.set_margin_end(6)
        group = None
        for key, label in (
            ("follow", "Follow System"),
            ("light", "Light"),
            ("sepia", "Sepia"),
            ("dark", "Dark"),
        ):
            button = Gtk.CheckButton(label=label)
            if group is None:
                group = button
            else:
                button.set_group(group)
            button.set_active(self._theme == key)
            button.connect("toggled", self._on_theme_toggled, key)
            box.append(button)
        popover.set_child(box)
        return popover

    def _on_theme_toggled(self, button: Gtk.CheckButton, key: str) -> None:
        if not button.get_active():
            return
        self._theme = key
        self._write_config("reader_theme", key)
        self._apply_style()

    def _on_dark_changed(self, *_args) -> None:
        if self._theme == "follow":
            self._apply_style()

    def _change_font_scale(self, delta: float) -> None:
        new_scale = round((self._font_scale + delta) * 10) / 10
        new_scale = min(_MAX_FONT_SCALE, max(_MIN_FONT_SCALE, new_scale))
        if new_scale == self._font_scale:
            return
        self._font_scale = new_scale
        self._write_config("reader_font_scale", new_scale)
        self._apply_style()

    def _apply_style(self) -> None:
        if self._kind == "pdf":
            # font_scale feeds the render scale; cached pages are stale.
            self._pdf_cache.clear()
            self._show_item(self._index, 0)
        elif self._webview is not None:
            self._eval(_INJECT_CSS_JS % json.dumps(self._reader_css()))

    def _reader_css(self) -> str:
        theme = self._theme
        if theme == "follow":
            dark = Adw.StyleManager.get_default().get_dark()
            theme = "dark" if dark else "light"
        background, foreground, link = _THEMES.get(theme, _THEMES["light"])
        percent = int(round(self._font_scale * 100))
        css = (
            "body { max-width: 46em; margin: 1em auto; padding: 0 1em;"
            f" line-height: 1.15; font-size: {percent}%;"
            f" background: {background}; color: {foreground}; }}"
            " img { max-width: 100%; height: auto; }"
        )
        if link:
            css += f" a {{ color: {link}; }}"
        return css

    def _toggle_fullscreen(self) -> None:
        root = self.get_root()
        if not isinstance(root, Gtk.Window):
            return
        if root.is_fullscreen():
            root.unfullscreen()
        else:
            root.fullscreen()

    def _toast(self, message: str) -> None:
        root = self.get_root()
        if root is not None and hasattr(root, "show_toast"):
            root.show_toast(message)

    # -- TOC / highlights panels -------------------------------------------------

    def _clear_box(self, box: Gtk.Box) -> None:
        while (child := box.get_first_child()) is not None:
            box.remove(child)

    def _refresh_toc(self) -> None:
        self._clear_box(self._toc_box)
        for i, (_key, title) in enumerate(self._items):
            button = Gtk.Button(label=title or f"Page {i + 1}")
            button.add_css_class("flat")
            button.set_tooltip_text(title)
            label = button.get_child()
            if isinstance(label, Gtk.Label):
                label.set_ellipsize(Pango.EllipsizeMode.END)
                label.set_xalign(0.0)
                if i == self._index:
                    label.add_css_class("heading")
            button.connect("clicked", self._on_toc_row, i)
            self._toc_box.append(button)

    def _on_toc_row(self, button: Gtk.Button, index: int) -> None:
        popover = button.get_ancestor(Gtk.Popover)
        if popover is not None:
            popover.popdown()
        if index == self._index:
            return
        direction = 1 if index > self._index else -1
        self._show_item(index, direction)

    def _list_highlights(self) -> list[dict]:
        if self._library is None or self._book.id is None:
            return []
        try:
            return self._library.list_highlights(self._book.id)
        except Exception as exc:  # db contract may be absent
            logger.warning("list_highlights failed: %s", exc)
            return []

    def _refresh_highlights(self) -> None:
        if self._hl_box is None:
            return
        self._clear_box(self._hl_box)
        highlights = self._list_highlights()
        if not highlights:
            empty = Gtk.Label(label="No highlights yet")
            empty.add_css_class("dim-label")
            empty.set_margin_top(12)
            empty.set_margin_bottom(12)
            self._hl_box.append(empty)
            return
        for hl in highlights:
            try:
                pos = json.loads(hl.get("position") or "{}")
            except (ValueError, TypeError):
                pos = {}
            quote = pos.get("quote") or (hl.get("text") or "")[:120]
            color = hl.get("color") or "yellow"
            hl_id = hl.get("id")

            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
            jump = Gtk.Button()
            jump.add_css_class("flat")
            jump.set_hexpand(True)
            inner = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            dot = Gtk.Box(width_request=12, height_request=12,
                          valign=Gtk.Align.CENTER)
            dot.add_css_class("vellum-hl-dot")
            dot.add_css_class(f"hl-dot-{color}")
            inner.append(dot)
            label = Gtk.Label(label=quote, xalign=0.0, hexpand=True,
                              ellipsize=Pango.EllipsizeMode.END,
                              max_width_chars=48)
            inner.append(label)
            jump.set_child(inner)
            jump.set_tooltip_text("Jump to highlight")
            jump.connect("clicked", self._on_highlight_jump, hl)
            row.append(jump)

            delete = Gtk.Button(icon_name="user-trash-symbolic")
            delete.add_css_class("flat")
            delete.set_tooltip_text("Delete highlight")
            delete.connect("clicked", self._on_highlight_delete, hl_id)
            row.append(delete)
            self._hl_box.append(row)

    def _on_highlight_jump(self, button: Gtk.Button, hl: dict) -> None:
        popover = button.get_ancestor(Gtk.Popover)
        if popover is not None:
            popover.popdown()
        try:
            pos = json.loads(hl.get("position") or "{}")
        except (ValueError, TypeError):
            return
        chapter = pos.get("chapter")
        start = pos.get("start")
        if chapter is None or start is None:
            return
        chapter = int(chapter)
        if not 0 <= chapter < len(self._items):
            return
        if chapter == self._index:
            self._eval(
                "window.__vellumJump && window.__vellumJump(%d);" % int(start)
            )
            return
        self._pending_jump = int(start)
        direction = 1 if chapter > self._index else -1
        self._show_item(chapter, direction)

    def _on_highlight_delete(self, _button: Gtk.Button, hl_id) -> None:
        if hl_id is None:
            return
        if self._library is not None:
            try:
                self._library.delete_highlight(int(hl_id))
            except Exception as exc:
                logger.warning("delete_highlight failed: %s", exc)
        self._eval(
            "window.__vellumUnhighlight && window.__vellumUnhighlight(%d);"
            % int(hl_id)
        )
        self._refresh_highlights()

    # -- content builders -------------------------------------------------------

    def _new_webview(self) -> WebKit.WebView:
        webview = WebKit.WebView(vexpand=True, hexpand=True)
        ucm = webview.get_user_content_manager()
        ucm.register_script_message_handler("vellum")
        ucm.connect("script-message-received::vellum",
                    self._on_script_message)
        webview.connect("load-changed", self._on_load_changed)
        # Item index the in-flight (or last) load belongs to; lets
        # load-changed tell stale loads apart from the current one.
        webview._vellum_pending_index = None
        self._webviews.append(webview)
        return webview

    def _pool_webview(self) -> WebKit.WebView:
        """Return the pool's other webview, creating it if needed.

        Never grows the pool past two instances.
        """
        for webview in self._webviews:
            if webview is not self._webview:
                # Rapid navigation can outrun the transition's deferred
                # cleanup, leaving the pooled webview still parented to
                # the stack. Detach it before loading the next chapter,
                # otherwise GtkWidget refuses the reparent.
                parent = webview.get_parent()
                if parent is not None:
                    if isinstance(parent, Gtk.Stack):
                        parent.remove(webview)
                    else:
                        webview.unparent()
                return webview
        if len(self._webviews) < 2:
            return self._new_webview()
        return self._webviews[0]

    def _build_content(self, index: int) -> Gtk.Widget:
        if self._kind == "pdf":
            self._webview = None
            data = self._pdf_cache_get(index)
            if data is not None:
                picture = self._pdf_picture(data)
                self._pdf_displayed_paintable = picture.get_paintable()
                return picture
            # Cache miss: never render on the main thread. Show the
            # previous page (or a spinner on first open) and swap in the
            # real page from _on_pdf_rendered once the worker finishes.
            placeholder = self._pdf_placeholder()
            self._start_pdf_render(index)
            return placeholder
        if self._kind == "mobi":
            html = self._mobi.section_html(index)
            section_path = os.path.join(
                self._cache_dir, "mobi", f"section-{index}.html"
            )
            with open(section_path, "w", encoding="utf-8") as fh:
                fh.write(html)
            webview = self._pool_webview()
            webview._vellum_pending_index = index
            self._webview = webview
            webview.load_uri(Path(section_path).as_uri())
            return webview
        webview = self._pool_webview()
        webview._vellum_pending_index = index
        self._webview = webview
        chapter_path = Path(self._epub.chapter_file(self._cache_dir, index))
        webview.load_uri(chapter_path.as_uri())
        return webview

    # -- pdf rendering (off the main thread) ------------------------------------

    def _pdf_effective_scale(self) -> float:
        return self._scale * self._font_scale

    @staticmethod
    def _pdf_picture(data: bytes) -> Gtk.Picture:
        texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))
        picture = Gtk.Picture.new_for_paintable(texture)
        picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        picture.set_can_shrink(True)
        picture.set_vexpand(True)
        picture.set_hexpand(True)
        return picture

    def _pdf_placeholder(self) -> Gtk.Widget:
        paintable = self._pdf_displayed_paintable
        if paintable is not None:
            picture = Gtk.Picture.new_for_paintable(paintable)
            picture.set_content_fit(Gtk.ContentFit.CONTAIN)
            picture.set_can_shrink(True)
            picture.set_vexpand(True)
            picture.set_hexpand(True)
            return picture
        return Gtk.Spinner(
            spinning=True, width_request=48, height_request=48,
            halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER,
            vexpand=True, hexpand=True,
        )

    def _pdf_cache_get(self, index: int) -> bytes | None:
        try:
            data = self._pdf_cache.pop(index)
        except KeyError:
            return None
        self._pdf_cache[index] = data  # reinsert: mark most-recently-used
        return data

    def _pdf_cache_put(self, index: int, data: bytes) -> None:
        self._pdf_cache.pop(index, None)
        while len(self._pdf_cache) >= _PDF_CACHE_SIZE:
            self._pdf_cache.pop(next(iter(self._pdf_cache)))  # evict LRU
        self._pdf_cache[index] = data

    def _start_pdf_render(self, index: int) -> None:
        scale = self._pdf_effective_scale()
        self._pdf_render_serial += 1
        serial = self._pdf_render_serial

        def _worker() -> None:
            results: dict[int, bytes] = {}
            targets = [index]
            for neighbor in (index - 1, index + 1):
                if 0 <= neighbor < len(self._items):
                    targets.append(neighbor)
            for target in targets:
                if serial != self._pdf_render_serial:
                    return  # superseded by a newer nav/zoom
                if target in self._pdf_cache:
                    continue
                with self._pdf_lock:
                    try:
                        data = self._pdf.render_page(target, scale)
                    except Exception as exc:
                        logger.warning(
                            "pdf render failed for page %s: %s", target, exc
                        )
                        continue
                results[target] = data
            if results:
                GLib.idle_add(
                    self._on_pdf_rendered, serial, index, scale, results
                )

        threading.Thread(target=_worker, daemon=True).start()

    def _on_pdf_rendered(self, serial: int, index: int, scale: float,
                         results: dict[int, bytes]) -> bool:
        if scale != self._pdf_effective_scale():
            return False  # zoomed/font-scaled since: stale pixels, drop
        for target, data in results.items():
            self._pdf_cache_put(target, data)
        if index in results and self._index == index:
            picture = self._pdf_picture(results[index])
            self._pdf_displayed_paintable = picture.get_paintable()
            self._swap_content(picture, 0)
        return False

    # -- navigation -------------------------------------------------------------

    def prev_chapter(self) -> None:
        if self._index > 0:
            self._show_item(self._index - 1, -1)

    def next_chapter(self) -> None:
        if self._index < len(self._items) - 1:
            self._show_item(self._index + 1, 1)

    def _on_swipe(self, _gesture, velocity_x: float, velocity_y: float) -> None:
        direction = swipe_direction(velocity_x, velocity_y)
        if direction < 0:
            self.next_chapter()
        elif direction > 0:
            self.prev_chapter()

    def _animation_enabled(self) -> bool:
        return bool(self._read_config().get("reader_animation", True))

    def _swap_content(self, widget: Gtk.Widget, direction: int) -> None:
        old = self._stack.get_visible_child()
        old_name = self._stack.get_visible_child_name()
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
                # Only remove the exact page we replaced: fast navigation
                # may have reused this widget already under a new name.
                if self._stack.get_child_by_name(old_name) is old:
                    self._stack.remove(old)
                return False
            GLib.timeout_add(_ANIMATION_DURATION_MS + 50, _drop_old)

    def _show_item(self, index: int, direction: int) -> None:
        self._index = index
        self._cancel_position_flush()
        self._dismiss_selection_popover()
        try:
            content = self._build_content(index)
        except (ValueError, OSError, IndexError):
            if not self._stack.get_first_child():
                self._show_error()
            return
        self._swap_content(content, direction)
        _, title = self._items[index]
        self._title_label.set_label(title)
        prefix = {"pdf": "Page", "mobi": "Section"}.get(
            self._kind, ""
        )
        counter = f"{index + 1} / {len(self._items)}"
        self._counter_label.set_label(
            f"{prefix} {counter}" if prefix else counter
        )
        self._prev_button.set_sensitive(index > 0)
        self._next_button.set_sensitive(index < len(self._items) - 1)
        if self._items:
            self._progress.set_fraction((index + 1) / len(self._items))
        self._last_fraction = (
            self._pending_scroll if self._pending_scroll is not None else 0.0
        )
        self._save_position(self._last_fraction)

    # -- position persistence ------------------------------------------------------

    def _restore_position(self) -> tuple[int, float]:
        if self._library is None or self._book.id is None:
            return 0, 0.0
        try:
            locator = self._library.get_reading_position(self._book.id)
        except Exception as exc:
            logger.warning("get_reading_position failed: %s", exc)
            return 0, 0.0
        if not locator:
            return 0, 0.0
        parts = str(locator).split(":")
        if len(parts) != 3 or parts[0] != self._kind:
            return 0, 0.0
        try:
            index = int(parts[1])
            fraction = float(parts[2])
        except ValueError:
            return 0, 0.0
        if not 0 <= index < len(self._items):
            return 0, 0.0
        return index, max(0.0, min(1.0, fraction))

    def _cancel_position_flush(self) -> None:
        if self._position_flush_source:
            GLib.source_remove(self._position_flush_source)
            self._position_flush_source = 0

    def _flush_position(self) -> bool:
        self._position_flush_source = 0
        self._save_position(self._last_fraction)
        return GLib.SOURCE_REMOVE

    def _flush_position_on_unrealize(self, *_args) -> None:
        self._cancel_position_flush()
        self._save_position(self._last_fraction)

    def _save_position(self, fraction: float) -> None:
        self._last_position_write = time.monotonic()
        if self._library is None or self._book.id is None:
            return
        fraction = max(0.0, min(1.0, float(fraction)))
        locator = f"{self._kind}:{self._index}:{fraction:.4f}"
        try:
            self._library.set_reading_position(self._book.id, locator)
        except Exception as exc:
            logger.warning("set_reading_position failed: %s", exc)

    # -- webview ----------------------------------------------------------------

    def _eval(self, script: str) -> None:
        if self._webview is not None:
            self._webview.evaluate_javascript(script, -1, None, None, None)

    def _on_load_changed(self, webview: WebKit.WebView,
                         event: WebKit.LoadEvent) -> None:
        if event != WebKit.LoadEvent.FINISHED:
            return
        if webview is not self._webview:
            return
        index = getattr(webview, "_vellum_pending_index", None)
        if index is None or index != self._index:
            return  # stale load from a pooled webview's previous item
        webview.evaluate_javascript(
            _INJECT_CSS_JS % json.dumps(self._reader_css()),
            -1, None, None, None,
        )
        webview.evaluate_javascript(_BRIDGE_JS, -1, None, None, None)
        self._reapply_highlights(index)
        if self._pending_jump is not None:
            start = self._pending_jump
            self._pending_jump = None
            self._eval(
                "window.__vellumJump && window.__vellumJump(%d);" % start
            )
        elif self._pending_scroll is not None:
            fraction = self._pending_scroll
            self._pending_scroll = None
            self._eval(_SCROLL_TO_JS % max(0.0, min(1.0, fraction)))

    def _reapply_highlights(self, index: int) -> None:
        for hl in self._list_highlights():
            try:
                pos = json.loads(hl.get("position") or "{}")
            except (ValueError, TypeError):
                continue
            if pos.get("chapter") != index:
                continue
            try:
                start = int(pos["start"])
                end = int(pos["end"])
                hl_id = int(hl["id"])
            except (KeyError, TypeError, ValueError):
                continue
            self._apply_highlight_js(
                start, end, hl.get("color") or "yellow", hl_id
            )

    def _apply_highlight_js(self, start: int, end: int, color: str,
                            hl_id: int) -> None:
        script = (
            "window.__vellumHighlight && window.__vellumHighlight("
            "%d, %d, %s, %d);" % (start, end, json.dumps(color), hl_id)
        )
        self._eval(script)

    # -- script messages (selection / scroll) --------------------------------------

    def _on_script_message(self, ucm, value) -> None:
        webview = self._webview
        if webview is None or webview.get_user_content_manager() is not ucm:
            return
        if webview.is_loading():
            # A pooled webview can still deliver messages from the page
            # it is navigating away from; they belong to the old item.
            return
        try:
            data = json.loads(value.to_json(0))
        except Exception:
            return
        if not isinstance(data, dict):
            return
        msg_type = data.get("type")
        if msg_type == "selection":
            text = str(data.get("text") or "").strip()
            if not text:
                self._cancel_selection_timeout()
                return
            try:
                start = int(data.get("start"))
                end = int(data.get("end"))
            except (TypeError, ValueError):
                return
            if end <= start:
                return
            self._pending_selection = {
                "text": text, "start": start, "end": end,
            }
            self._schedule_selection_popover()
        elif msg_type == "scroll":
            try:
                fraction = float(data.get("fraction"))
            except (TypeError, ValueError):
                return
            self._last_fraction = max(0.0, min(1.0, fraction))
            # Coalesce DB writes: the JS throttle should already limit
            # us to ~1 message/sec, but never write more often than
            # _SCROLL_SAVE_MIN_INTERVAL; _show_item persists the latest
            # fraction on navigation.
            now = time.monotonic()
            elapsed = now - self._last_position_write
            if elapsed >= _SCROLL_SAVE_MIN_INTERVAL:
                self._save_position(self._last_fraction)
            elif not self._position_flush_source:
                # Keep the final position after a scroll stops.
                delay = int(
                    (_SCROLL_SAVE_MIN_INTERVAL - elapsed) * 1000
                ) + 1
                self._position_flush_source = GLib.timeout_add(
                    delay, self._flush_position
                )

    def _cancel_selection_timeout(self) -> None:
        if self._selection_source:
            GLib.source_remove(self._selection_source)
            self._selection_source = 0

    def _schedule_selection_popover(self) -> None:
        self._cancel_selection_timeout()

        def _show() -> bool:
            self._selection_source = 0
            self._show_selection_popover()
            return False

        self._selection_source = GLib.timeout_add(
            _SELECTION_DEBOUNCE_MS, _show
        )

    def _dismiss_selection_popover(self) -> None:
        self._cancel_selection_timeout()
        popover = self._selection_popover
        self._selection_popover = None
        if popover is not None:
            popover.popdown()

    def _pointer_rect(self, webview: WebKit.WebView) -> Gdk.Rectangle:
        try:
            seat = webview.get_display().get_default_seat()
            pointer = seat.get_pointer() if seat else None
            if pointer is not None:
                surface, x, y = pointer.get_surface_at_position()
                native = webview.get_native()
                if (surface is not None and native is not None
                        and surface == native.get_surface()):
                    point = Graphene.Point()
                    point.init(float(x), float(y))
                    ok, widget_point = native.compute_point(webview, point)
                    if ok:
                        return self._rect_at(
                            int(widget_point.x), int(widget_point.y)
                        )
        except Exception:
            pass
        alloc = webview.get_allocation()
        return self._rect_at(alloc.width - 48, 8)

    @staticmethod
    def _rect_at(x: int, y: int) -> Gdk.Rectangle:
        rect = Gdk.Rectangle()
        rect.x = x
        rect.y = y
        rect.width = 1
        rect.height = 1
        return rect

    def _show_selection_popover(self) -> None:
        self._dismiss_selection_popover()
        if not self._pending_selection or self._webview is None:
            return
        webview = self._webview
        popover = Gtk.Popover(
            autohide=True, has_arrow=True,
            position=Gtk.PositionType.TOP,
        )
        popover.set_pointing_to(self._pointer_rect(webview))

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(6)
        box.set_margin_end(6)

        caption = Gtk.Label(label="Highlight", xalign=0.0)
        caption.add_css_class("caption")
        caption.add_css_class("dim-label")
        box.append(caption)

        colors_row = Gtk.Box(spacing=6)
        colors_row.set_halign(Gtk.Align.CENTER)
        for color in _HIGHLIGHT_COLORS:
            dot = Gtk.Box(width_request=18, height_request=18)
            dot.add_css_class("vellum-hl-dot")
            dot.add_css_class(f"hl-dot-{color}")
            button = Gtk.Button(child=dot)
            button.add_css_class("flat")
            button.set_tooltip_text(f"Highlight {color}")
            button.connect("clicked", self._on_highlight_color, color)
            colors_row.append(button)
        box.append(colors_row)

        define = Gtk.Button(label="Define")
        define.add_css_class("flat")
        define.connect("clicked", self._on_define_clicked)
        box.append(define)

        popover.set_child(box)
        popover.set_parent(webview)
        popover.connect("closed", self._on_selection_popover_closed)
        popover.popup()
        self._selection_popover = popover

    def _on_selection_popover_closed(self, popover: Gtk.Popover) -> None:
        if self._selection_popover is popover:
            self._selection_popover = None
        if popover.get_parent() is not None:
            popover.unparent()

    # -- highlights -----------------------------------------------------------------

    def _on_highlight_color(self, _button: Gtk.Button, color: str) -> None:
        selection = self._pending_selection
        self._dismiss_selection_popover()
        if not selection:
            return
        position = json.dumps({
            "chapter": self._index,
            "start": selection["start"],
            "end": selection["end"],
            "quote": selection["text"][:200],
        })
        hl_id = None
        if self._library is not None and self._book.id is not None:
            try:
                hl_id = self._library.add_highlight(
                    self._book.id, position, color, selection["text"]
                )
            except Exception as exc:
                logger.warning("add_highlight failed: %s", exc)
        if hl_id is None:
            self._toast("Could not save highlight")
            return
        self._apply_highlight_js(
            selection["start"], selection["end"], color, int(hl_id)
        )
        self._eval(
            "window.getSelection && window.getSelection().removeAllRanges();"
        )

    # -- dictionary -------------------------------------------------------------------

    def _on_define_clicked(self, _button: Gtk.Button) -> None:
        selection = self._pending_selection
        self._dismiss_selection_popover()
        if not selection:
            return
        words = re.findall(r"[A-Za-z][A-Za-z'\-]*", selection["text"])
        if not words:
            self._toast("No definition found")
            return
        word = words[0]
        self._eval(
            "window.getSelection && window.getSelection().removeAllRanges();"
        )

        def _worker() -> None:
            try:
                from vellum.core.dictionary import lookup
                result = lookup(word)
            except Exception as exc:
                logger.warning("dictionary lookup failed: %s", exc)
                result = None
            GLib.idle_add(self._on_definition, word, result)

        threading.Thread(target=_worker, daemon=True).start()

    def _on_definition(self, word: str, entry: dict | None) -> bool:
        if not entry:
            self._toast("No definition found")
            return False
        dialog = Adw.Dialog(
            title=entry.get("word") or word,
            content_width=420,
            content_height=420,
        )
        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(Adw.HeaderBar())
        scroll = Gtk.ScrolledWindow(
            hscrollbar_policy=Gtk.PolicyType.NEVER,
            propagate_natural_height=True,
            propagate_natural_width=True,
        )
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_margin_top(12)
        box.set_margin_bottom(12)
        box.set_margin_start(12)
        box.set_margin_end(12)

        word_label = Gtk.Label(label=entry.get("word") or word, xalign=0.0)
        word_label.add_css_class("title-2")
        box.append(word_label)
        phonetic = (entry.get("phonetic") or "").strip()
        if phonetic:
            phon_label = Gtk.Label(label=phonetic, xalign=0.0)
            phon_label.add_css_class("dim-label")
            box.append(phon_label)

        for meaning in entry.get("meanings") or []:
            part = (meaning.get("partOfSpeech") or "").strip()
            if part:
                part_label = Gtk.Label(label=part, xalign=0.0)
                part_label.add_css_class("heading")
                part_label.set_margin_top(6)
                box.append(part_label)
            for definition in meaning.get("definitions") or []:
                def_label = Gtk.Label(
                    label=f"• {definition}",
                    xalign=0.0,
                    wrap=True,
                    wrap_mode=Pango.WrapMode.WORD_CHAR,
                    selectable=True,
                )
                box.append(def_label)

        scroll.set_child(box)
        toolbar.set_content(scroll)
        dialog.set_child(toolbar)
        dialog.present(self)
        return False

    # -- keys / zoom ----------------------------------------------------------------

    def _on_key_pressed(self, _controller, keyval: int, _keycode: int,
                        state: Gdk.ModifierType) -> bool:
        if keyval == Gdk.KEY_F11:
            self._toggle_fullscreen()
            return True
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
        self._pdf_cache.clear()  # cached pages were rendered at old scale
        self._show_item(self._index, 0)
        return True

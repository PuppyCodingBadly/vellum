"""Cover-grid library view."""

from __future__ import annotations

import os
import queue
import threading
import weakref

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, GObject, Gtk, Pango  # noqa: F401  (Adw: css classes)

from vellum.core.covers import thumb_path
from vellum.core.models import Book

COVER_WIDTH = 160
COVER_HEIGHT = 240


class BookObject(GObject.Object):
    """GObject wrapper so a :class:`vellum.core.models.Book` fits Gio.ListStore."""

    __gtype_name__ = "VellumBookObject"

    def __init__(self, book: Book):
        super().__init__()
        self.book = book


def _initials(title: str) -> str:
    words = [w for w in (title or "").split() if w]
    if not words:
        return "?"
    return "".join(w[0] for w in words[:2]).upper()


class LibraryView(Gtk.ScrolledWindow):
    """Grid of cover cards backed by the library's books."""

    def __init__(self, on_activate=None):
        super().__init__(hexpand=True, vexpand=True)
        self._on_activate = on_activate
        self._data_dir = os.path.join(GLib.get_user_data_dir(), "vellum")

        self._store = Gio.ListStore(item_type=BookObject)
        self._selection = Gtk.SingleSelection(model=self._store)

        factory = Gtk.SignalListItemFactory()
        factory.connect("setup", self._on_factory_setup)
        factory.connect("bind", self._on_factory_bind)

        self._grid = Gtk.GridView(model=self._selection, factory=factory)
        self._grid.set_margin_top(12)
        self._grid.set_margin_bottom(12)
        self._grid.set_margin_start(12)
        self._grid.set_margin_end(12)
        self._grid.connect("activate", self._on_grid_activate)
        self.set_child(self._grid)

        # Lazy thumbnail generation on a single daemon worker thread.
        self._thumb_queue: queue.Queue = queue.Queue()
        self._thumb_pending: set[int] = set()
        self._thumb_lock = threading.Lock()
        self._thumb_cards: dict[int, weakref.ref] = {}
        worker = threading.Thread(target=self._thumb_worker, daemon=True)
        worker.start()

    # -- public API ---------------------------------------------------------

    def set_books(self, books: list[Book]) -> None:
        self._thumb_cards.clear()
        self._store.remove_all()
        for book in books:
            self._store.append(BookObject(book))

    # -- factory ------------------------------------------------------------

    def _build_card(self) -> Gtk.Box:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.set_size_request(COVER_WIDTH, 300)
        card.set_margin_top(6)
        card.set_margin_bottom(6)
        card.set_margin_start(6)
        card.set_margin_end(6)

        frame = Gtk.Frame(css_classes=["cover-frame"])

        cover_stack = Gtk.Stack(hexpand=True, vexpand=True)
        picture = Gtk.Picture(content_fit=Gtk.ContentFit.COVER, can_shrink=True)
        placeholder = Gtk.Label(
            css_classes=["cover-placeholder"], hexpand=True, vexpand=True
        )
        cover_stack.add_named(picture, "cover")
        cover_stack.add_named(placeholder, "placeholder")
        cover_stack.set_visible_child_name("placeholder")
        frame.set_child(cover_stack)
        aspect = Gtk.AspectFrame(
            ratio=2.0 / 3.0,
            obey_child=False,
            xalign=0.5,
            yalign=0.5,
        )
        aspect.set_child(frame)
        aspect.set_size_request(COVER_WIDTH, -1)
        center_box = Gtk.CenterBox(
            orientation=Gtk.Orientation.HORIZONTAL,
            hexpand=True,
            vexpand=False,
            valign=Gtk.Align.START,
        )
        center_box.set_center_widget(aspect)
        card.append(center_box)

        title = Gtk.Label(
            wrap=False,
            ellipsize=Pango.EllipsizeMode.END,
            max_width_chars=18,
            xalign=0.0,
            justify=Gtk.Justification.CENTER,
            css_classes=["caption-heading"],
        )
        authors = Gtk.Label(
            wrap=False,
            ellipsize=Pango.EllipsizeMode.END,
            max_width_chars=18,
            xalign=0.0,
            justify=Gtk.Justification.CENTER,
            css_classes=["dim-label", "caption"],
        )
        card.append(title)
        card.append(authors)

        card._cover_stack = cover_stack
        card._picture = picture
        card._placeholder = placeholder
        card._title_label = title
        card._authors_label = authors
        return card

    def _on_factory_setup(self, _factory, item: Gtk.ListItem) -> None:
        item.set_child(self._build_card())

    def _on_factory_bind(self, _factory, item: Gtk.ListItem) -> None:
        obj = item.get_item()
        if obj is None:
            return
        book = obj.book
        card = item.get_child()

        card._title_label.set_label(book.title or "Untitled")
        card._authors_label.set_label(
            ", ".join(book.authors) if book.authors else "Unknown author"
        )

        if book.cover_path and os.path.isfile(book.cover_path):
            card._book_id = book.id
            if book.id is not None:
                self._thumb_cards[book.id] = weakref.ref(card)
            thumb = os.path.join(
                self._data_dir, "covers", "thumbs", f"{book.id}.png"
            )
            if os.path.isfile(thumb) and os.path.getmtime(
                thumb
            ) >= os.path.getmtime(book.cover_path):
                card._picture.set_filename(thumb)
                card._cover_stack.set_visible_child_name("cover")
            else:
                card._picture.set_filename(None)
                card._placeholder.set_label(_initials(book.title))
                card._cover_stack.set_visible_child_name("placeholder")
                self._request_thumb(book)
        else:
            card._book_id = None
            card._picture.set_filename(None)
            card._placeholder.set_label(_initials(book.title))
            card._cover_stack.set_visible_child_name("placeholder")

    # -- thumbnail worker ---------------------------------------------------

    def _request_thumb(self, book: Book) -> None:
        if book.id is None:
            return
        with self._thumb_lock:
            if book.id in self._thumb_pending:
                return
            self._thumb_pending.add(book.id)
        self._thumb_queue.put((book.id, book.cover_path))

    def _thumb_worker(self) -> None:
        while True:
            book_id, cover_path = self._thumb_queue.get()
            try:
                thumb = thumb_path(self._data_dir, book_id, cover_path)
                if thumb != cover_path:
                    GLib.idle_add(self._apply_thumb, book_id, thumb)
            finally:
                with self._thumb_lock:
                    self._thumb_pending.discard(book_id)

    def _apply_thumb(self, book_id: int, thumb: str) -> bool:
        ref = self._thumb_cards.get(book_id)
        card = ref() if ref is not None else None
        if card is not None and getattr(card, "_book_id", None) == book_id:
            card._picture.set_filename(thumb)
            card._cover_stack.set_visible_child_name("cover")
        return False

    # -- activation ---------------------------------------------------------

    def _on_grid_activate(self, _grid: Gtk.GridView, position: int) -> None:
        obj = self._store.get_item(position)
        if obj is not None and self._on_activate is not None:
            self._on_activate(obj.book)

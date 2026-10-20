"""Cover-grid library view."""

from __future__ import annotations

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GObject, Gtk, Pango  # noqa: F401  (Adw: css classes)

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

    # -- public API ---------------------------------------------------------

    def set_books(self, books: list[Book]) -> None:
        self._store.remove_all()
        for book in books:
            self._store.append(BookObject(book))

    # -- factory ------------------------------------------------------------

    def _build_card(self) -> Gtk.Box:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        card.set_size_request(COVER_WIDTH, -1)
        card.set_margin_top(6)
        card.set_margin_bottom(6)
        card.set_margin_start(6)
        card.set_margin_end(6)

        frame = Gtk.Frame(css_classes=["cover-frame"])
        frame.set_size_request(COVER_WIDTH, COVER_HEIGHT)

        cover_stack = Gtk.Stack()
        picture = Gtk.Picture(content_fit=Gtk.ContentFit.COVER, can_shrink=True)
        picture.set_size_request(COVER_WIDTH, COVER_HEIGHT)
        placeholder = Gtk.Label(
            css_classes=["cover-placeholder"], hexpand=True, vexpand=True
        )
        cover_stack.add_named(picture, "cover")
        cover_stack.add_named(placeholder, "placeholder")
        cover_stack.set_visible_child_name("placeholder")
        frame.set_child(cover_stack)
        card.append(frame)

        title = Gtk.Label(
            wrap=True,
            lines=2,
            ellipsize=Pango.EllipsizeMode.END,
            max_width_chars=18,
            justify=Gtk.Justification.CENTER,
            css_classes=["caption-heading"],
        )
        authors = Gtk.Label(
            ellipsize=Pango.EllipsizeMode.END,
            max_width_chars=22,
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
            card._picture.set_filename(book.cover_path)
            card._cover_stack.set_visible_child_name("cover")
        else:
            card._picture.set_filename(None)
            card._placeholder.set_label(_initials(book.title))
            card._cover_stack.set_visible_child_name("placeholder")

    # -- activation ---------------------------------------------------------

    def _on_grid_activate(self, _grid: Gtk.GridView, position: int) -> None:
        obj = self._store.get_item(position)
        if obj is not None and self._on_activate is not None:
            self._on_activate(obj.book)

"""Book details panel."""

from __future__ import annotations

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk, Pango

from vellum.core.models import Book

from vellum.ui.library_view import _initials

DETAIL_COVER_WIDTH = 180
DETAIL_COVER_HEIGHT = 260

_DETAIL_FIELDS = (
    ("publisher", "Publisher"),
    ("pubdate", "Published"),
    ("language", "Language"),
    ("isbn", "ISBN"),
)


class BookDetails(Gtk.Box):
    """Scrollable panel showing every field of a single book."""

    def __init__(self, book: Book, library, engine, data_dir: str, window,
                 on_changed=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL)
        self._book = book
        self._library = library
        self._engine = engine
        self._data_dir = data_dir
        self._window = window
        self._on_changed = on_changed

        scrolled = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        self.append(scrolled)
        clamp = Adw.Clamp(maximum_size=780)
        scrolled.set_child(clamp)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        content.set_margin_top(24)
        content.set_margin_bottom(24)
        content.set_margin_start(24)
        content.set_margin_end(24)
        clamp.set_child(content)

        # -- header: cover + title block -----------------------------------
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        content.append(top)

        frame = Gtk.Frame(css_classes=["cover-frame"])
        frame.set_size_request(DETAIL_COVER_WIDTH, DETAIL_COVER_HEIGHT)
        frame.set_valign(Gtk.Align.START)
        self._cover_stack = Gtk.Stack()
        self._picture = Gtk.Picture(
            content_fit=Gtk.ContentFit.COVER, can_shrink=True
        )
        self._picture.set_size_request(DETAIL_COVER_WIDTH, DETAIL_COVER_HEIGHT)
        self._placeholder = Gtk.Label(
            css_classes=["cover-placeholder"], hexpand=True, vexpand=True
        )
        self._cover_stack.add_named(self._picture, "cover")
        self._cover_stack.add_named(self._placeholder, "placeholder")
        frame.set_child(self._cover_stack)
        top.append(frame)

        right = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=8,
            valign=Gtk.Align.START,
            hexpand=True,
        )
        top.append(right)

        self._title_label = Gtk.Label(xalign=0, wrap=True)
        self._title_label.add_css_class("title-1")
        right.append(self._title_label)

        self._authors_label = Gtk.Label(xalign=0, wrap=True)
        self._authors_label.add_css_class("title-3")
        self._authors_label.add_css_class("dim-label")
        right.append(self._authors_label)

        self._rating_label = Gtk.Label(xalign=0)
        right.append(self._rating_label)

        self._tags_flow = Gtk.FlowBox(
            selection_mode=Gtk.SelectionMode.NONE,
            column_spacing=6,
            row_spacing=6,
            max_children_per_line=8,
        )
        right.append(self._tags_flow)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        actions.set_margin_top(8)
        fetch = Gtk.Button(label="Fetch Metadata")
        fetch.add_css_class("suggested-action")
        fetch.connect("clicked", self._on_fetch_clicked)
        actions.append(fetch)
        self._read_button = Gtk.Button(label="Read")
        self._read_button.add_css_class("suggested-action")
        self._read_button.connect("clicked", self._on_read_clicked)
        self._read_button.set_visible(
            bool({f.lower() for f in (book.formats or [])} & {"epub", "pdf", "mobi", "azw3"})
            and bool(book.path)
            and os.path.isfile(book.path)
        )
        actions.append(self._read_button)
        right.append(actions)

        # -- detail rows -----------------------------------------------------
        group = Adw.PreferencesGroup(title="Details")
        self._rows: dict[str, Adw.ActionRow] = {}
        for field, label in _DETAIL_FIELDS:
            row = Adw.ActionRow(title=label)
            self._rows[field] = row
            group.add(row)
        content.append(group)

        # -- description ------------------------------------------------------
        desc_heading = Gtk.Label(label="Description", xalign=0)
        desc_heading.add_css_class("heading")
        content.append(desc_heading)

        desc_scroll = Gtk.ScrolledWindow(
            min_content_height=90,
            max_content_height=220,
            propagate_natural_height=True,
        )
        desc_scroll.add_css_class("card")
        self._description_label = Gtk.Label(
            xalign=0,
            yalign=0,
            wrap=True,
            wrap_mode=Pango.WrapMode.WORD_CHAR,
            selectable=True,
        )
        self._description_label.set_margin_top(12)
        self._description_label.set_margin_bottom(12)
        self._description_label.set_margin_start(12)
        self._description_label.set_margin_end(12)
        desc_scroll.set_child(self._description_label)
        content.append(desc_scroll)

        self.refresh()

    # -- public API ---------------------------------------------------------

    def refresh(self) -> None:
        """Re-render every field from the current book."""
        book = self._book

        self._title_label.set_label(book.title or "Untitled")
        self._authors_label.set_label(
            ", ".join(book.authors) if book.authors else "Unknown author"
        )

        rating = book.rating or 0.0
        stars_n = max(0, min(5, int(round(rating))))
        stars = "★" * stars_n + "☆" * (5 - stars_n)
        self._rating_label.set_label(
            f"{stars}  {rating:.1f}" if rating else stars
        )

        while (child := self._tags_flow.get_first_child()) is not None:
            self._tags_flow.remove(child)
        for tag in book.tags:
            chip = Gtk.Label(label=tag, css_classes=["tag-chip"])
            self._tags_flow.append(chip)
        self._tags_flow.set_visible(bool(book.tags))

        for field, _label in _DETAIL_FIELDS:
            value = getattr(book, field, "") or ""
            row = self._rows[field]
            row.set_subtitle(value)
            row.set_visible(bool(value))

        self._description_label.set_label(
            book.description or "No description available."
        )

        if book.cover_path and os.path.isfile(book.cover_path):
            self._picture.set_filename(book.cover_path)
            self._cover_stack.set_visible_child_name("cover")
        else:
            self._picture.set_filename(None)
            self._placeholder.set_label(_initials(book.title))
            self._cover_stack.set_visible_child_name("placeholder")

        self._read_button.set_visible(
            bool({f.lower() for f in (book.formats or [])} & {"epub", "pdf", "mobi", "azw3"})
            and bool(book.path)
            and os.path.isfile(book.path)
        )

    # -- internals ----------------------------------------------------------

    def _on_fetch_clicked(self, _button: Gtk.Button) -> None:
        from vellum.ui.metadata_dialog import MetadataDialog

        dialog = MetadataDialog(
            window=self._window,
            engine=self._engine,
            library=self._library,
            data_dir=self._data_dir,
            book=self._book,
            on_applied=self._on_metadata_applied,
        )
        dialog.present_dialog()

    def _on_read_clicked(self, _button: Gtk.Button) -> None:
        from vellum.ui.reader_view import ReaderPage

        page = Adw.NavigationPage(
            child=ReaderPage(self._book, self._data_dir),
            title=self._book.title or "Reader",
        )
        self._window.nav.push(page)

    def _on_metadata_applied(self) -> None:
        self.refresh()
        if self._on_changed is not None:
            self._on_changed()

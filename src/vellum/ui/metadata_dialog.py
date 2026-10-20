"""Metadata search/apply dialog.

All network access happens on worker threads; results are marshalled back to
the main loop with GLib.idle_add so the UI never blocks.
"""

from __future__ import annotations

import logging
import os
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk, Pango

from vellum.core.models import Book
from vellum.metadata.sources.base import Metadata

logger = logging.getLogger(__name__)

_HAS_ADW_DIALOG = hasattr(Adw, "Dialog")
_Base = Adw.Dialog if _HAS_ADW_DIALOG else Adw.Window


class MetadataDialog(_Base):
    """Searches registered metadata sources and applies a chosen result."""

    def __init__(self, window, engine, library, data_dir: str, book: Book,
                 on_applied=None):
        super().__init__()
        self._window = window
        self._engine = engine
        self._library = library
        self._data_dir = data_dir
        self._book = book
        self._on_applied = on_applied
        self._applying = False

        if _HAS_ADW_DIALOG:
            self.set_title("Fetch Metadata")
            self.set_content_width(560)
            self.set_content_height(520)
        else:
            self.set_title("Fetch Metadata")
            self.set_default_size(560, 520)
            self.set_modal(True)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        self._apply_button = Gtk.Button(label="Apply", sensitive=False)
        self._apply_button.add_css_class("suggested-action")
        self._apply_button.connect("clicked", self._on_apply_clicked)
        header.pack_end(self._apply_button)
        toolbar.add_top_bar(header)

        self._stack = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE,
            hexpand=True,
            vexpand=True,
        )

        busy = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=12,
            valign=Gtk.Align.CENTER,
            hexpand=True,
            vexpand=True,
        )
        spinner = Gtk.Spinner(spinning=True, width_request=32, height_request=32)
        busy.append(spinner)
        status = Gtk.Label(label="Searching metadata sources…")
        status.add_css_class("dim-label")
        busy.append(status)
        self._stack.add_named(busy, "busy")

        scrolled = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        self._list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self._list.add_css_class("boxed-list")
        self._list.set_margin_top(12)
        self._list.set_margin_bottom(12)
        self._list.set_margin_start(12)
        self._list.set_margin_end(12)
        self._list.connect("row-selected", self._on_row_selected)
        scrolled.set_child(self._list)
        self._stack.add_named(scrolled, "results")

        self._status_page = Adw.StatusPage(
            title="No Results",
            description="No metadata source returned a match.",
            icon_name="edit-find-symbolic",
            vexpand=True,
        )
        self._stack.add_named(self._status_page, "empty")

        toolbar.set_content(self._stack)
        self.set_content(toolbar)
        self._stack.set_visible_child_name("busy")

    # -- public API ---------------------------------------------------------

    def present_dialog(self) -> None:
        if _HAS_ADW_DIALOG:
            self.present(self._window)
        else:
            self.set_transient_for(self._window)
            self.present()
        self._start_search()

    # -- search -------------------------------------------------------------

    def _start_search(self) -> None:
        book = self._book
        query = {
            "title": book.title or "",
            "authors": list(book.authors) if book.authors else None,
            "isbn": book.isbn or "",
        }

        def work() -> None:
            try:
                results = self._engine.find(**query)
            except Exception as exc:  # network/parse failures
                logger.warning("Metadata search failed: %s", exc)
                GLib.idle_add(self._on_search_done, None, exc)
            else:
                GLib.idle_add(self._on_search_done, results, None)

        threading.Thread(
            target=work, name="vellum-metadata-search", daemon=True
        ).start()

    def _on_search_done(self, results, error) -> bool:
        if error is not None:
            self._toast(f"Metadata search failed: {error}")
            self._status_page.set_title("Search Failed")
            self._status_page.set_description(str(error))
            self._stack.set_visible_child_name("empty")
            return GLib.SOURCE_REMOVE

        if not results:
            self._stack.set_visible_child_name("empty")
            return GLib.SOURCE_REMOVE

        for meta in results:
            self._list.append(self._build_row(meta))
        self._stack.set_visible_child_name("results")
        return GLib.SOURCE_REMOVE

    def _build_row(self, meta: Metadata) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow()
        row._meta = meta

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(8)
        box.set_margin_end(8)

        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2,
                       hexpand=True)
        title = Gtk.Label(label=meta.title or "Untitled", xalign=0,
                          ellipsize=Pango.EllipsizeMode.END)
        title.add_css_class("heading")
        left.append(title)

        authors = Gtk.Label(
            label=", ".join(meta.authors) if meta.authors else "Unknown author",
            xalign=0,
            ellipsize=Pango.EllipsizeMode.END,
        )
        authors.add_css_class("dim-label")
        left.append(authors)

        origin_bits = [meta.source_name or meta.source_id or "Unknown source"]
        if meta.isbn:
            origin_bits.append(f"ISBN {meta.isbn}")
        origin = Gtk.Label(label=" · ".join(origin_bits), xalign=0,
                           ellipsize=Pango.EllipsizeMode.END)
        origin.add_css_class("dim-label")
        origin.add_css_class("caption")
        left.append(origin)
        box.append(left)

        if meta.rating:
            rating = Gtk.Label(label=f"★ {meta.rating:.1f}",
                               valign=Gtk.Align.CENTER)
            box.append(rating)

        row.set_child(box)
        return row

    def _on_row_selected(self, _listbox, row) -> None:
        self._apply_button.set_sensitive(row is not None and not self._applying)

    # -- apply ----------------------------------------------------------------

    def _on_apply_clicked(self, _button: Gtk.Button) -> None:
        row = self._list.get_selected_row()
        if row is None:
            return
        meta: Metadata = row._meta
        book = self._book

        # Map metadata fields onto the book (keep existing values as fallback).
        book.title = meta.title or book.title
        book.authors = list(meta.authors) if meta.authors else book.authors
        book.isbn = meta.isbn or book.isbn
        book.publisher = meta.publisher or book.publisher
        book.pubdate = meta.pubdate or book.pubdate
        book.language = meta.language or book.language
        book.description = meta.description or book.description
        book.tags = list(meta.tags) if meta.tags else book.tags
        if meta.rating:
            book.rating = meta.rating

        self._applying = True
        self._apply_button.set_sensitive(False)
        self._apply_button.set_label("Applying…")

        def work() -> None:
            cover_error = None
            try:
                data = self._engine.fetch_cover(meta)
                if data:
                    covers_dir = os.path.join(self._data_dir, "covers")
                    os.makedirs(covers_dir, exist_ok=True)
                    cover_id = book.id if book.id is not None else "new"
                    path = os.path.join(covers_dir, f"{cover_id}.jpg")
                    with open(path, "wb") as handle:
                        handle.write(data)
                    book.cover_path = path
            except Exception as exc:  # cover is best-effort
                logger.warning("Cover download failed: %s", exc)
                cover_error = exc
            GLib.idle_add(self._on_apply_done, cover_error)

        threading.Thread(
            target=work, name="vellum-metadata-apply", daemon=True
        ).start()

    def _on_apply_done(self, cover_error) -> bool:
        if cover_error is not None:
            self._toast(f"Cover download failed: {cover_error}")

        try:
            self._library.update_book(self._book)
        except Exception as exc:
            logger.warning("Failed to save book: %s", exc)
            self._toast(f"Failed to save book: {exc}")
            self._applying = False
            self._apply_button.set_label("Apply")
            self._apply_button.set_sensitive(True)
            return GLib.SOURCE_REMOVE

        self._toast("Metadata applied")
        if self._on_applied is not None:
            self._on_applied()
        self.close()
        return GLib.SOURCE_REMOVE

    # -- helpers --------------------------------------------------------------

    def _toast(self, message: str) -> None:
        show = getattr(self._window, "show_toast", None)
        if callable(show):
            show(message)
        else:
            logger.info("Toast: %s", message)

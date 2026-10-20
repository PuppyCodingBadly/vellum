"""Metadata search/apply dialog.

All network access happens on worker threads; results are marshalled back to
the main loop with GLib.idle_add so the UI never blocks.
"""

from __future__ import annotations

import logging
import os
import queue
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gdk", "4.0")
from gi.repository import Adw, Gdk, GLib, Gtk, Pango

from vellum.core.models import Book
from vellum.metadata.sources.base import Metadata
from vellum.metadata.sorting import (
    RESULT_SORT_KEYS,
    RESULT_SORT_OPTIONS,
    sort_metadata,
)
from vellum.metadata.universal import normalize_url

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
            self.set_content_width(620)
            self.set_content_height(580)
        else:
            self.set_title("Fetch Metadata")
            self.set_default_size(620, 580)
            self.set_modal(True)

        toolbar = Adw.ToolbarView()
        header = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
            css_classes=["vellum-header"],
        )
        title_label = Gtk.Label(
            label="Fetch Metadata", hexpand=True, xalign=0.0
        )
        title_label.add_css_class("heading")
        header.append(title_label)
        self._apply_button = Gtk.Button(label="Apply", sensitive=False)
        self._apply_button.add_css_class("suggested-action")
        self._apply_button.connect("clicked", self._on_apply_clicked)
        header.append(self._apply_button)
        close_button = Gtk.Button(icon_name="window-close-symbolic")
        close_button.set_tooltip_text("Close")
        close_button.connect("clicked", lambda *_args: self.close())
        header.append(close_button)
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
        self._busy_label = Gtk.Label(label="Searching metadata sources…")
        self._busy_label.add_css_class("dim-label")
        busy.append(self._busy_label)
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

        query_bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
            margin_top=6,
            margin_start=12,
            margin_end=12,
        )
        self._query_entry = Gtk.SearchEntry(
            placeholder_text="Search metadata by title, author, or ISBN…",
            hexpand=True,
        )
        self._query_entry.connect("activate", self._on_query_search)
        query_bar.append(self._query_entry)
        self._search_button = Gtk.Button(
            label="Search", valign=Gtk.Align.CENTER
        )
        self._search_button.connect("clicked", self._on_query_search)
        query_bar.append(self._search_button)
        self._result_sort = Gtk.DropDown(
            model=Gtk.StringList.new(
                [label for _key, label in RESULT_SORT_OPTIONS]
            ),
            tooltip_text="Sort results",
            valign=Gtk.Align.CENTER,
        )
        self._result_sort.set_selected(0)
        self._result_sort.connect(
            "notify::selected", self._on_result_sort_changed
        )
        query_bar.append(self._result_sort)

        url_bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
            margin_top=6,
            margin_bottom=6,
            margin_start=12,
            margin_end=12,
        )
        self._url_entry = Gtk.Entry(
            placeholder_text="Paste a book page URL…",
            hexpand=True,
        )
        self._url_entry.connect("activate", self._on_grab_url)
        url_bar.append(self._url_entry)
        self._grab_button = Gtk.Button(label="Grab", valign=Gtk.Align.CENTER)
        self._grab_button.connect("clicked", self._on_grab_url)
        url_bar.append(self._grab_button)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        content.append(query_bar)
        content.append(url_bar)
        content.append(self._stack)
        toolbar.set_content(content)
        if _HAS_ADW_DIALOG:
            self.set_child(toolbar)
        else:
            self.set_content(toolbar)
        self._stack.set_visible_child_name("busy")

        self._request_id = 0
        self._results: list[Metadata] = []
        self._result_sort_key = "relevance"
        self._select_first = False
        self._render_serial = 0
        self._cover_queue: queue.Queue = queue.Queue()
        self._cover_cache: dict[str, bytes | None] = {}
        self._cover_failed: set[str] = set()
        self._cover_waiters: dict[str, list[tuple]] = {}
        threading.Thread(
            target=self._cover_worker,
            name="vellum-metadata-covers",
            daemon=True,
        ).start()

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
        request_id = self._begin_request("Searching metadata sources…")

        def work() -> None:
            try:
                results = self._engine.find_all(**query)
            except Exception as exc:  # network/parse failures
                logger.warning("Metadata search failed: %s", exc)
                GLib.idle_add(self._on_search_done, None, exc, request_id)
            else:
                GLib.idle_add(self._on_search_done, results, None, request_id)

        threading.Thread(
            target=work, name="vellum-metadata-search", daemon=True
        ).start()

    def _on_query_search(self, *_args) -> None:
        query = self._query_entry.get_text().strip()
        if not query:
            self._toast("Enter a title, author, or ISBN to search")
            return
        request_id = self._begin_request("Searching metadata sources…")
        self._search_button.set_sensitive(False)

        def work() -> None:
            try:
                results = self._engine.find_query(query)
            except Exception as exc:
                logger.warning("Metadata query failed: %s", exc)
                GLib.idle_add(self._on_query_done, None, exc, request_id)
            else:
                GLib.idle_add(self._on_query_done, results, None, request_id)

        threading.Thread(
            target=work, name="vellum-metadata-query", daemon=True
        ).start()

    def _on_query_done(self, results, error, request_id) -> bool:
        self._search_button.set_sensitive(True)
        if request_id != self._request_id:
            return GLib.SOURCE_REMOVE
        if error is not None:
            self._show_error("Search Failed", f"Metadata search failed: {error}")
            return GLib.SOURCE_REMOVE
        if not results:
            self._status_page.set_title("No Results")
            self._status_page.set_description(
                "No metadata source matched that string."
            )
            self._stack.set_visible_child_name("empty")
            return GLib.SOURCE_REMOVE
        self._show_results(results)
        return GLib.SOURCE_REMOVE

    def _begin_request(self, message: str) -> int:
        self._request_id += 1
        self._busy_label.set_label(message)
        self._stack.set_visible_child_name("busy")
        while (child := self._list.get_first_child()) is not None:
            self._list.remove(child)
        self._results = []
        self._apply_button.set_sensitive(False)
        return self._request_id

    def _on_grab_url(self, *_args) -> None:
        text = self._url_entry.get_text().strip()
        if not text:
            self._toast("Paste a book page URL first")
            return
        url = normalize_url(text)
        if not url:
            # A title/author string was pasted into the URL field; run the
            # fuzzy metadata search instead of raising an invalid-URL error.
            self._query_entry.set_text(text)
            self._on_query_search()
            return
        request_id = self._begin_request("Reading book page…")
        self._grab_button.set_sensitive(False)

        def work() -> None:
            try:
                meta = self._engine.grab_url(url)
            except Exception as exc:
                logger.warning("URL metadata grab failed: %s", exc)
                GLib.idle_add(self._on_url_done, None, exc, request_id)
            else:
                GLib.idle_add(self._on_url_done, meta, None, request_id)

        threading.Thread(
            target=work, name="vellum-metadata-url", daemon=True
        ).start()

    def _on_search_done(self, results, error, request_id) -> bool:
        if request_id != self._request_id:
            return GLib.SOURCE_REMOVE
        if error is not None:
            self._show_error("Search Failed", f"Metadata search failed: {error}")
            return GLib.SOURCE_REMOVE
        if not results:
            self._status_page.set_title("No Results")
            self._status_page.set_description(
                "No metadata source returned a match."
            )
            self._stack.set_visible_child_name("empty")
            return GLib.SOURCE_REMOVE
        self._show_results(results)
        return GLib.SOURCE_REMOVE

    def _on_url_done(self, meta, error, request_id) -> bool:
        self._grab_button.set_sensitive(True)
        if request_id != self._request_id:
            return GLib.SOURCE_REMOVE
        if error is not None:
            self._show_error("Grab Failed", f"Could not read that page: {error}")
            return GLib.SOURCE_REMOVE
        if meta is None:
            self._status_page.set_title("No Metadata Found")
            self._status_page.set_description(
                "The page did not contain recognizable book metadata."
            )
            self._stack.set_visible_child_name("empty")
            return GLib.SOURCE_REMOVE
        self._show_results([meta], select=True)
        return GLib.SOURCE_REMOVE

    def _show_results(self, results: list[Metadata], select: bool = False) -> None:
        self._results = list(results)
        self._select_first = select
        self._render_results()

    def _render_results(self) -> None:
        had_selection = self._list.get_selected_row() is not None
        while (child := self._list.get_first_child()) is not None:
            self._list.remove(child)
        self._render_serial += 1
        serial = self._render_serial
        for meta in sort_metadata(self._results, self._result_sort_key):
            self._list.append(self._build_row(meta, serial))
        self._stack.set_visible_child_name("results")
        if (self._select_first or had_selection) and (
            self._list.get_row_at_index(0) is not None
        ):
            self._list.select_row(self._list.get_row_at_index(0))

    def _on_result_sort_changed(self, dropdown, _param) -> None:
        index = dropdown.get_selected()
        if 0 <= index < len(RESULT_SORT_KEYS):
            self._result_sort_key = RESULT_SORT_KEYS[index]
        if self._results:
            self._render_results()

    def _show_error(self, title: str, message: str) -> None:
        self._toast(message)
        self._status_page.set_title(title)
        self._status_page.set_description(message)
        self._stack.set_visible_child_name("empty")

    def _build_row(self, meta: Metadata, serial: int = 0) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow()
        row._meta = meta

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(8)
        box.set_margin_end(8)

        preview_stack = Gtk.Stack(
            width_request=48, height_request=72,
            hhomogeneous=False, vhomogeneous=False,
        )
        preview = Gtk.Picture(
            content_fit=Gtk.ContentFit.COVER, can_shrink=True
        )
        placeholder = Gtk.Image.new_from_icon_name(
            "image-x-generic-symbolic"
        )
        placeholder.set_pixel_size(18)
        placeholder.add_css_class("dim-label")
        placeholder.set_halign(Gtk.Align.CENTER)
        placeholder.set_valign(Gtk.Align.CENTER)
        preview_stack.add_named(preview, "cover")
        preview_stack.add_named(placeholder, "placeholder")
        preview_stack.set_visible_child_name("placeholder")
        preview_frame = Gtk.Frame(css_classes=["metadata-cover"])
        preview_frame.set_child(preview_stack)
        preview_aspect = Gtk.AspectFrame(
            ratio=2.0 / 3.0, obey_child=False, xalign=0.5, yalign=0.5
        )
        preview_aspect.set_child(preview_frame)
        preview_aspect.set_size_request(48, 72)
        box.append(preview_aspect)

        left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2,
                       hexpand=True, valign=Gtk.Align.CENTER)
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
        row._cover_picture = preview
        row._cover_stack = preview_stack
        self._request_cover(meta, preview, preview_stack, serial)
        return row

    # -- cover previews --------------------------------------------------------

    def _cover_worker(self) -> None:
        while True:
            meta = self._cover_queue.get()
            try:
                data = self._engine.fetch_cover(meta)
            except Exception as exc:
                logger.warning("Metadata cover fetch failed: %s", exc)
                data = None
            GLib.idle_add(self._apply_cover, meta.cover_url, data)

    def _request_cover(
        self, meta: Metadata, picture: Gtk.Picture,
        stack: Gtk.Stack, serial: int,
    ) -> None:
        url = meta.cover_url
        if not url:
            return
        if url in self._cover_cache:
            data = self._cover_cache[url]
            if data:
                self._set_cover(picture, stack, data)
            return
        if url in self._cover_failed:
            return
        waiters = self._cover_waiters.setdefault(url, [])
        waiters.append((picture, stack, serial))
        if len(waiters) == 1:
            self._cover_queue.put(meta)

    def _apply_cover(self, url: str, data: bytes | None) -> bool:
        if data:
            self._cover_cache[url] = data
        else:
            self._cover_failed.add(url)
            self._cover_cache[url] = None
        for picture, stack, serial in self._cover_waiters.pop(url, []):
            if serial == self._render_serial and data:
                self._set_cover(picture, stack, data)
        return GLib.SOURCE_REMOVE

    @staticmethod
    def _set_cover(
        picture: Gtk.Picture, stack: Gtk.Stack, data: bytes
    ) -> None:
        try:
            texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(data))
            picture.set_paintable(texture)
            stack.set_visible_child_name("cover")
        except Exception as exc:
            logger.warning("Metadata cover preview failed: %s", exc)

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

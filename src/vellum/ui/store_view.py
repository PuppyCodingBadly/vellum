"""'Get Books' view: search calibre store plugins and download books.

Consumes vellum.core.store.StoreAdapter / StoreResult. All adapter and
network work happens on daemon threads; results are marshalled back to the
main loop with GLib.idle_add so the UI never blocks.
"""

from __future__ import annotations

import logging
import os
import re
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, GLib, Gtk, Pango

logger = logging.getLogger(__name__)


def _safe_filename(name: str, default: str = "book") -> str:
    """Strip path-hostile characters and clamp length for a download name."""
    name = re.sub(r"[^\w\-. ]+", "", name, flags=re.UNICODE).strip(" .")
    return name[:80] or default


class StoreView(Gtk.Box):
    def __init__(self, stores: list, library, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self._stores = list(stores or [])
        self._library = library
        self._window = window
        self._searching = False
        self._store_picker: Gtk.DropDown | None = None

        self._stack = Gtk.Stack(vexpand=True)
        self.append(self._stack)

        if not self._stores:
            page = Adw.StatusPage(
                title="No store plugins",
                description="Add a calibre store plugin zip from the Plugins page",
                icon_name="folder-download-symbolic",
                vexpand=True,
            )
            self._stack.add_named(page, "empty")
            return

        self.append(self._build_search_bar())

        self._status_bin = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL, vexpand=True
        )
        self._scrolled = Gtk.ScrolledWindow(vexpand=True)
        self._list = Gtk.ListBox(
            css_classes=["boxed-list"],
            margin_top=12,
            margin_bottom=12,
            margin_start=12,
            margin_end=12,
        )
        self._list.set_selection_mode(Gtk.SelectionMode.NONE)
        self._scrolled.set_child(self._list)
        self._stack.add_named(self._scrolled, "results")
        self._stack.add_named(self._status_bin, "status")
        self._show_status(
            "Search for books",
            "Enter a query above to find books available for download.",
            "system-search-symbolic",
        )

    # -- UI construction -------------------------------------------------------

    def _build_search_bar(self) -> Gtk.Box:
        bar = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=6,
            margin_top=12,
            margin_bottom=6,
            margin_start=12,
            margin_end=12,
        )
        self._entry = Gtk.SearchEntry(
            placeholder_text="Search stores…", hexpand=True
        )
        self._entry.connect("activate", self._on_search)
        bar.append(self._entry)

        if len(self._stores) > 1:
            names = Gtk.StringList()
            for adapter in self._stores:
                names.append(adapter.name)
            self._store_picker = Gtk.DropDown(model=names)
            self._store_picker.set_selected(0)
            bar.append(self._store_picker)

        self._search_button = Gtk.Button(
            label="Search", css_classes=["suggested-action"]
        )
        self._search_button.connect("clicked", self._on_search)
        bar.append(self._search_button)

        self._spinner = Gtk.Spinner()
        bar.append(self._spinner)
        return bar

    def _show_status(self, title: str, description: str, icon: str) -> None:
        while (child := self._status_bin.get_first_child()) is not None:
            self._status_bin.remove(child)
        self._status_bin.append(
            Adw.StatusPage(
                title=title, description=description, icon_name=icon,
                vexpand=True,
            )
        )
        self._stack.set_visible_child_name("status")

    def _populate(self, adapter, results: list) -> None:
        while (child := self._list.get_first_child()) is not None:
            self._list.remove(child)
        for result in results:
            self._list.append(self._build_row(adapter, result))
        self._stack.set_visible_child_name("results")

    def _build_row(self, adapter, result) -> Gtk.ListBoxRow:
        row = Gtk.ListBoxRow()
        box = Gtk.Box(
            orientation=Gtk.Orientation.HORIZONTAL,
            spacing=12,
            margin_top=6,
            margin_bottom=6,
            margin_start=12,
            margin_end=12,
        )
        text = Gtk.Box(
            orientation=Gtk.Orientation.VERTICAL,
            spacing=2,
            hexpand=True,
            valign=Gtk.Align.CENTER,
        )
        text.append(
            Gtk.Label(
                label=result.title or "Untitled",
                xalign=0,
                css_classes=["heading"],
                ellipsize=Pango.EllipsizeMode.END,
            )
        )
        if result.author:
            text.append(
                Gtk.Label(
                    label=result.author,
                    xalign=0,
                    css_classes=["dim-label"],
                    ellipsize=Pango.EllipsizeMode.END,
                )
            )
        meta = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        if result.formats:
            meta.append(
                Gtk.Label(
                    label=result.formats,
                    css_classes=["tag-chip", "caption"],
                )
            )
        if result.store_name:
            meta.append(
                Gtk.Label(
                    label=result.store_name,
                    xalign=0,
                    valign=Gtk.Align.CENTER,
                    css_classes=["caption", "dim-label"],
                )
            )
        if meta.get_first_child() is not None:
            text.append(meta)
        box.append(text)

        button = Gtk.Button(label="Download", valign=Gtk.Align.CENTER)
        button.connect("clicked", self._on_download, adapter, result, button)
        box.append(button)
        row.set_child(box)
        return row

    # -- search flow -------------------------------------------------------------

    def _selected_adapter(self):
        if self._store_picker is not None:
            index = self._store_picker.get_selected()
            if 0 <= index < len(self._stores):
                return self._stores[index]
        return self._stores[0]

    def _on_search(self, *_args) -> None:
        if self._searching:
            return
        query = self._entry.get_text().strip()
        if not query:
            return
        adapter = self._selected_adapter()
        self._searching = True
        self._spinner.start()
        self._search_button.set_sensitive(False)
        threading.Thread(
            target=self._search_worker, args=(adapter, query), daemon=True
        ).start()

    def _search_worker(self, adapter, query: str) -> None:
        try:
            results = adapter.search(query)
        except Exception as exc:
            logger.warning(
                "Store search failed (%s): %s", adapter.name, exc
            )
            results = None
        GLib.idle_add(self._on_search_done, adapter, results)

    def _on_search_done(self, adapter, results) -> bool:
        self._searching = False
        self._spinner.stop()
        self._search_button.set_sensitive(True)
        if not results:
            self._show_status(
                "No results",
                "Try a different query or store.",
                "system-search-symbolic",
            )
            return GLib.SOURCE_REMOVE
        self._populate(adapter, results)
        return GLib.SOURCE_REMOVE

    # -- download flow -----------------------------------------------------------

    def _on_download(self, _button, adapter, result, button) -> None:
        spinner = Gtk.Spinner()
        button.set_sensitive(False)
        button.set_child(spinner)
        spinner.start()
        threading.Thread(
            target=self._download_worker,
            args=(button, adapter, result),
            daemon=True,
        ).start()

    def _download_worker(self, button, adapter, result) -> None:
        try:
            fetched = adapter.fetch_download(result)
        except Exception as exc:
            logger.warning(
                "fetch_download failed (%s): %s", adapter.name, exc
            )
            fetched = None
        if fetched is None or not fetched.download_url:
            GLib.idle_add(
                self._on_download_error, button, "Could not resolve download link"
            )
            return
        try:
            path = self._download_file(fetched)
        except Exception as exc:
            logger.warning("Download failed: %s", exc)
            GLib.idle_add(
                self._on_download_error, button, f"Download failed: {exc}"
            )
            return
        try:
            from vellum.core.importer import import_path

            ids = import_path(self._library, path)
        except Exception as exc:
            logger.warning("Import failed: %s", exc)
            GLib.idle_add(
                self._on_download_error, button, f"Import failed: {exc}"
            )
            return
        GLib.idle_add(self._on_download_ok, button, fetched, bool(ids))

    def _download_file(self, result) -> str:
        import requests

        downloads_dir = os.path.join(self._data_dir(), "downloads")
        os.makedirs(downloads_dir, exist_ok=True)

        ext = (result.formats or "epub").split(",")[0].strip().lower()
        ext = re.sub(r"[^a-z0-9]", "", ext) or "epub"
        filename = f"{_safe_filename(result.title)}.{ext}"
        path = os.path.join(downloads_dir, filename)
        stem, suffix = os.path.splitext(path)
        counter = 1
        while os.path.exists(path):
            path = f"{stem} ({counter}){suffix}"
            counter += 1

        with requests.get(result.download_url, timeout=120, stream=True) as resp:
            resp.raise_for_status()
            with open(path, "wb") as handle:
                for chunk in resp.iter_content(chunk_size=1 << 16):
                    if chunk:
                        handle.write(chunk)
        return path

    # -- main-loop callbacks -------------------------------------------------------

    def _on_download_error(self, button, message: str) -> bool:
        self._restore_button(button)
        self._toast(message)
        return GLib.SOURCE_REMOVE

    def _on_download_ok(self, button, result, imported: bool) -> bool:
        self._restore_button(button)
        if imported:
            self._toast(f"Added {result.title or 'book'} to library")
            try:
                self._window.refresh_library()
            except Exception as exc:
                logger.warning("refresh_library failed: %s", exc)
        else:
            self._toast(f"Downloaded {result.title or 'book'}")
        return GLib.SOURCE_REMOVE

    def _restore_button(self, button) -> None:
        button.set_child(Gtk.Label(label="Download"))
        button.set_sensitive(True)

    def _toast(self, message: str) -> None:
        try:
            self._window.show_toast(message)
        except Exception:
            logger.info("Toast: %s", message)

    def _data_dir(self) -> str:
        return getattr(self._window, "data_dir", None) or os.path.join(
            GLib.get_user_data_dir(), "vellum"
        )

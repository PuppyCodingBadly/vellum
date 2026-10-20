"""Main application window."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk

from vellum.core.models import Book

from vellum.ui.book_details import BookDetails
from vellum.ui.library_view import LibraryView
from vellum.ui.plugins_view import PluginsView
from vellum.ui.store_view import StoreView

SEARCH_DEBOUNCE_MS = 300


class VellumWindow(Adw.ApplicationWindow):
    def __init__(self, application, library, engine, plugin_manager,
                 data_dir: str, stores=None, **kwargs):
        super().__init__(application=application, **kwargs)
        self.library = library
        self.engine = engine
        self.plugin_manager = plugin_manager
        self.data_dir = data_dir
        self.stores = list(stores or [])

        self.set_title("Vellum")
        self.set_default_size(1100, 750)

        # Toast overlay wraps everything so notifications show over any page.
        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        self.nav = Adw.NavigationView()
        self.toast_overlay.set_child(self.nav)

        toolbar_view = Adw.ToolbarView()
        header = Adw.HeaderBar()

        self.stack = Adw.ViewStack()
        switcher = Adw.ViewSwitcher(
            stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE
        )
        header.pack_start(switcher)

        self.search_entry = Gtk.SearchEntry(
            placeholder_text="Search library…", width_chars=36
        )
        header.set_title_widget(self.search_entry)

        menu = Gio.Menu()
        menu.append("Preferences", "app.preferences")
        menu.append("About Vellum", "app.about")
        menu.append("Close Window", "window.close")
        menu.append("Quit", "app.quit")
        menu_button = Gtk.MenuButton(
            icon_name="open-menu-symbolic", menu_model=menu
        )
        header.pack_end(menu_button)

        toolbar_view.add_top_bar(header)

        self.library_view = LibraryView(on_activate=self.show_book_details)
        self.plugins_view = PluginsView(plugin_manager, window=self)
        self.store_view = StoreView(self.stores, library=self.library, window=self)
        self.stack.add_titled_with_icon(
            self.library_view, "library", "Library", "view-grid-symbolic"
        )
        self.stack.add_titled_with_icon(
            self.store_view, "store", "Get Books", "folder-download-symbolic"
        )
        self.stack.add_titled_with_icon(
            self.plugins_view, "plugins", "Plugins", "application-x-addon-symbolic"
        )

        toolbar_view.set_content(self.stack)

        root_page = Adw.NavigationPage(child=toolbar_view, title="Vellum")
        self.nav.add(root_page)

        # Debounced search.
        self._search_source = 0
        self.search_entry.connect("search-changed", self._on_search_changed)

        # Ctrl+F focuses the search entry.
        shortcuts = Gtk.ShortcutController()
        shortcuts.add_shortcut(
            Gtk.Shortcut(
                trigger=Gtk.ShortcutTrigger.parse_string("<Control>f"),
                action=Gtk.CallbackAction.new(self._focus_search),
            )
        )
        self.add_controller(shortcuts)

        self.refresh_library()

    # -- public API -----------------------------------------------------------

    def refresh_library(self) -> None:
        """Reload the grid from the library, honoring the current query."""
        query = self.search_entry.get_text().strip()
        books = self.library.search(query) if query else self.library.all_books()
        self.library_view.set_books(books)

    def show_book_details(self, book: Book) -> None:
        details = BookDetails(
            book=book,
            library=self.library,
            engine=self.engine,
            data_dir=self.data_dir,
            window=self,
            on_changed=self.refresh_library,
        )
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        tv.set_content(details)
        page = Adw.NavigationPage(
            child=tv, title=book.title or "Book Details"
        )
        self.nav.push(page)

    def show_toast(self, message: str) -> None:
        self.toast_overlay.add_toast(Adw.Toast(title=message, timeout=3))

    def add_store(self, adapter) -> None:
        """Register a store plugin installed while the window is open."""
        if any(getattr(s, "name", None) == adapter.name for s in self.stores):
            return
        self.stores.append(adapter)
        self.store_view.add_store(adapter)

    # -- internals --------------------------------------------------------------

    def _on_search_changed(self, _entry: Gtk.SearchEntry) -> None:
        if self._search_source:
            GLib.source_remove(self._search_source)
            self._search_source = 0
        self._search_source = GLib.timeout_add(
            SEARCH_DEBOUNCE_MS, self._run_search
        )

    def _run_search(self) -> bool:
        self._search_source = 0
        self.refresh_library()
        return GLib.SOURCE_REMOVE

    def _focus_search(self, *_args) -> bool:
        if self.stack.get_visible_child_name() != "library":
            self.stack.set_visible_child_name("library")
        self.search_entry.grab_focus()
        return True

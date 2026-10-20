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

        # A plain Gtk.Stack avoids Adw.NavigationView's touch back gesture
        # and automatic header back button. Those have crashed the shell
        # on touchscreen devices; this stack uses explicit buttons instead.
        self.pages = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.NONE,
            hexpand=True,
            vexpand=True,
        )
        self.toast_overlay.set_child(self.pages)
        self._page_names: list[str] = []
        self._page_seq = 0

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
        menu.append("Import Calibre Library…", "app.import-calibre")
        menu.append("Show Hidden Books", "app.show-hidden")
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

        self.pages.add_named(toolbar_view, "root")
        self._page_names.append("root")
        self.pages.set_visible_child_name("root")

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
        shortcuts.add_shortcut(
            Gtk.Shortcut(
                trigger=Gtk.ShortcutTrigger.parse_string("<Alt>Left"),
                action=Gtk.CallbackAction.new(self._on_back_shortcut),
            )
        )
        self.add_controller(shortcuts)

        self.refresh_library()

    # -- public API -----------------------------------------------------------

    def refresh_library(self) -> None:
        """Reload the grid from the library, honoring the current query."""
        query = self.search_entry.get_text().strip()
        application = self.get_application()
        include_hidden = bool(
            getattr(application, "config", {}).get("show_hidden", False)
        )
        if query:
            books = self.library.search(query, include_hidden=include_hidden)
        else:
            books = self.library.all_books(include_hidden=include_hidden)
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
        self.push_page(details, book.title or "Book Details")

    def push_page(self, content: Gtk.Widget, title: str) -> None:
        """Show *content* as a new page with an explicit back button."""
        toolbar_view = Adw.ToolbarView()
        header = Adw.HeaderBar()
        back = Gtk.Button(icon_name="go-previous-symbolic")
        back.set_tooltip_text("Back")
        back.connect("clicked", self._on_back_clicked)
        header.pack_start(back)
        header.set_title_widget(Adw.WindowTitle(title=title))
        toolbar_view.add_top_bar(header)
        toolbar_view.set_content(content)

        self._page_seq += 1
        name = f"page-{self._page_seq}"
        self.pages.add_named(toolbar_view, name)
        self._page_names.append(name)
        self.pages.set_visible_child_name(name)

    def pop_page(self) -> bool:
        """Return to the previous page. Returns False at the root."""
        if len(self._page_names) <= 1:
            return False
        current = self._page_names.pop()
        self.pages.set_visible_child_name(self._page_names[-1])
        # Never destroy a page (and its WebKit views) inside the back
        # button's event dispatch; tearing down surfaces synchronously on
        # a touch tap is what triggered compositor crashes on some
        # devices. Show the previous page now, remove the old one on idle.
        GLib.idle_add(self._remove_page, current)
        return True

    def _remove_page(self, name: str) -> bool:
        child = self.pages.get_child_by_name(name)
        if child is not None:
            self.pages.remove(child)
        return GLib.SOURCE_REMOVE

    def _on_back_clicked(self, *_args) -> None:
        self.pop_page()

    def _on_back_shortcut(self, *_args) -> bool:
        return self.pop_page()

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

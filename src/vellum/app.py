"""Vellum application entry point.

Run with ``python -m vellum.app`` (installed) or ``python src/vellum/app.py``
from a source checkout (bootstrap below puts ``src`` on sys.path).
"""

from __future__ import annotations

import json
import logging
import os
import sys

if __package__ in (None, ""):
    sys.path.insert(
        0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    )

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gdk, Gtk

from vellum.core.db import Library
from vellum.core.models import Book
from vellum.metadata.engine import MetadataEngine
from vellum.plugins.manager import PluginManager
from vellum.ui.window import VellumWindow

try:
    from vellum import __version__
except Exception:  # package metadata not available (bare source tree)
    __version__ = "0.1.0"

logger = logging.getLogger(__name__)

APP_ID = "io.github.vellum.Vellum"
APP_NAME = "Vellum"

CSS = """
.cover-frame {
    border-radius: 8px;
}
.cover-placeholder {
    background: @accent_bg_color;
    color: @accent_fg_color;
    border-radius: 8px;
    font-weight: bold;
    font-size: 32px;
}
.tag-chip {
    background: alpha(@accent_color, 0.15);
    color: @accent_color;
    border-radius: 999px;
    padding: 2px 10px;
}
"""

DEMO_BOOKS = [
    Book(
        title="The Left Hand of Darkness",
        authors=["Ursula K. Le Guin"],
        isbn="9780441478125",
        publisher="Ace Books",
        pubdate="1969",
        language="en",
        description=(
            "A lone human envoy must win over the ambisexual inhabitants of "
            "the icebound planet Gethen to the cause of the Ekumen."
        ),
        tags=["Science Fiction", "Classic"],
        rating=4.5,
    ),
    Book(
        title="Pride and Prejudice",
        authors=["Jane Austen"],
        isbn="9780141439518",
        publisher="Penguin Classics",
        pubdate="1813",
        language="en",
        description=(
            "Elizabeth Bennet spars with the proud Mr. Darcy in Austen's "
            "enduring comedy of manners."
        ),
        tags=["Romance", "Classic"],
        rating=4.3,
    ),
    Book(
        title="The Hobbit",
        authors=["J. R. R. Tolkien"],
        isbn="9780547928227",
        publisher="Houghton Mifflin",
        pubdate="1937",
        language="en",
        description=(
            "Bilbo Baggins is swept from his comfortable hole into a quest "
            "for dragon-guarded treasure."
        ),
        tags=["Fantasy", "Adventure"],
        rating=4.7,
    ),
    Book(
        title="Clean Code",
        authors=["Robert C. Martin"],
        isbn="9780132350884",
        publisher="Prentice Hall",
        pubdate="2008",
        language="en",
        description=(
            "A handbook of agile software craftsmanship: principles, "
            "patterns, and practices of writing maintainable code."
        ),
        tags=["Programming", "Software"],
        rating=4.4,
    ),
    Book(
        title="Dune",
        authors=["Frank Herbert"],
        isbn="9780441172719",
        publisher="Ace Books",
        pubdate="1965",
        language="en",
        description=(
            "Paul Atreides rises on the desert world Arrakis, the only "
            "source of the spice melange."
        ),
        tags=["Science Fiction"],
        rating=4.6,
    ),
]


class VellumApplication(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id=APP_ID,
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self.add_main_option(
            "version",
            0,
            GLib.OptionFlags.NONE,
            GLib.OptionArg.NONE,
            "Print version and exit",
            None,
        )
        self.data_dir: str = ""
        self.library: Library | None = None
        self.engine: MetadataEngine | None = None
        self.plugin_manager: PluginManager | None = None

    # -- GApplication hooks ----------------------------------------------------

    def do_handle_local_options(self, options):
        if options.contains("version"):
            print(__version__)
            return 0
        return -1

    def do_startup(self):
        Adw.Application.do_startup(self)
        self._load_css()
        self._setup_actions()
        self._setup_backend()

    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = VellumWindow(
                application=self,
                library=self.library,
                engine=self.engine,
                plugin_manager=self.plugin_manager,
                data_dir=self.data_dir,
            )
        window.present()

    # -- setup -------------------------------------------------------------------

    def _load_css(self) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_string(CSS)
        display = Gdk.Display.get_default()
        if display is not None:
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

    def _setup_actions(self) -> None:
        about = Gio.SimpleAction(name="about")
        about.connect("activate", self._on_about)
        self.add_action(about)

        quit_action = Gio.SimpleAction(name="quit")
        quit_action.connect("activate", lambda *_args: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Ctrl>q"])

    def _setup_backend(self) -> None:
        self.data_dir = os.path.join(GLib.get_user_data_dir(), "vellum")
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(os.path.join(self.data_dir, "covers"), exist_ok=True)

        # Library location comes from a plain JSON config file.
        config_path = os.path.join(self.data_dir, "config.json")
        config: dict = {}
        if os.path.isfile(config_path):
            try:
                with open(config_path, "r", encoding="utf-8") as handle:
                    config = json.load(handle)
            except (OSError, ValueError) as exc:
                logger.warning("Ignoring unreadable config %s: %s", config_path, exc)
        library_path = config.get("library_path") or os.path.join(
            self.data_dir, "library.db"
        )
        if config.get("library_path") != library_path:
            try:
                with open(config_path, "w", encoding="utf-8") as handle:
                    json.dump({"library_path": library_path}, handle, indent=2)
            except OSError as exc:
                logger.warning("Could not write config %s: %s", config_path, exc)

        self.library = Library(library_path)
        self.library.open()

        self.engine = MetadataEngine()
        self._register_builtin_sources()

        self.plugin_manager = PluginManager(
            self.engine, os.path.join(self.data_dir, "plugins")
        )
        try:
            self.plugin_manager.load_all()
        except Exception as exc:
            logger.warning("Plugin loading failed: %s", exc)

        if not self.library.all_books():
            self._seed_demo_books()

    def _register_builtin_sources(self) -> None:
        try:
            from vellum.metadata.sources import GoogleBooks, OpenLibrary

            self.engine.register_source(GoogleBooks())
            self.engine.register_source(OpenLibrary())
        except Exception as exc:
            logger.warning("Could not register metadata sources: %s", exc)

    def _seed_demo_books(self) -> None:
        for book in DEMO_BOOKS:
            try:
                self.library.add_book(book)
            except Exception as exc:
                logger.warning("Failed to seed '%s': %s", book.title, exc)

    # -- actions -----------------------------------------------------------------

    def _on_about(self, *_args) -> None:
        parent = self.get_active_window()
        if hasattr(Adw, "AboutDialog"):
            dialog = Adw.AboutDialog(
                application_name=APP_NAME,
                application_icon=APP_ID,
                version=__version__,
                developer_name="Vellum developers",
                license_type=Gtk.License.MIT_X11,
                comments="A calibre-like ebook library manager.",
            )
            dialog.present(parent)
        else:
            about_window = Adw.AboutWindow(
                transient_for=parent,
                application_name=APP_NAME,
                application_icon=APP_ID,
                version=__version__,
                developer_name="Vellum developers",
                license_type=Gtk.License.MIT_X11,
                comments="A calibre-like ebook library manager.",
            )
            about_window.present()


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO)
    app = VellumApplication()
    return app.run(sys.argv if argv is None else list(argv))


if __name__ == "__main__":
    raise SystemExit(main())

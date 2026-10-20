"""Vellum application entry point.

Run with ``python -m vellum.app`` (installed) or ``python src/vellum/app.py``
from a source checkout (bootstrap below puts ``src`` on sys.path).
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading

if __package__ in (None, ""):
    sys.path.insert(
        0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    )

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gdk, Gtk

from vellum.core.db import Library
from vellum.metadata.engine import MetadataEngine
from vellum.plugins.manager import PluginManager
from vellum.ui.window import VellumWindow

try:
    from vellum import __version__
except Exception:  # package metadata not available (bare source tree)
    __version__ = "0.1.1"

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
.hidden-book {
    opacity: 0.55;
}
"""

# Libadwaita 1.9 accent palette: name -> (bg/color, fg) hex pairs.
ACCENTS = {
    "blue": ("#3584e4", "#ffffff"),
    "teal": ("#2190a4", "#ffffff"),
    "green": ("#3a944a", "#ffffff"),
    "yellow": ("#c88800", "#ffffff"),
    "orange": ("#ed5b00", "#ffffff"),
    "red": ("#e62d42", "#ffffff"),
    "pink": ("#d56199", "#ffffff"),
    "purple": ("#9141ac", "#ffffff"),
    "slate": ("#6f8396", "#ffffff"),
}

# Titles that 0.1.0 seeded into a new library. Existing installs are
# cleaned up once, matched by title and by having no file path so a real
# imported book with the same title survives.
LEGACY_DEMO_TITLES = {
    "The Left Hand of Darkness",
    "Pride and Prejudice",
    "The Hobbit",
    "Clean Code",
    "Dune",
}


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
        self.config: dict = {}
        self.config_path: str = ""
        self._accent_provider: Gtk.CssProvider | None = None
        self.library: Library | None = None
        self.engine: MetadataEngine | None = None
        self.plugin_manager: PluginManager | None = None
        self.stores: list = []
        self.startup_warning: str = ""
        self._calibre_import_running: bool = False

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
        self.apply_appearance()

    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = VellumWindow(
                application=self,
                library=self.library,
                engine=self.engine,
                plugin_manager=self.plugin_manager,
                data_dir=self.data_dir,
                stores=self.stores,
            )
        window.present()
        if self.startup_warning:
            window.show_toast(self.startup_warning)
            self.startup_warning = ""

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

        preferences = Gio.SimpleAction(name="preferences")
        preferences.connect("activate", self._on_preferences)
        self.add_action(preferences)

        quit_action = Gio.SimpleAction(name="quit")
        quit_action.connect("activate", lambda *_args: self.quit())
        self.add_action(quit_action)
        self.set_accels_for_action("app.quit", ["<Ctrl>q"])

        show_hidden = Gio.SimpleAction(
            name="show-hidden",
            state=GLib.Variant("b", bool(self.config.get("show_hidden", False))),
        )
        show_hidden.connect("activate", self._on_show_hidden)
        self.add_action(show_hidden)

        import_calibre = Gio.SimpleAction(name="import-calibre")
        import_calibre.connect("activate", self._on_import_calibre)
        self.add_action(import_calibre)

    def _setup_backend(self) -> None:
        self.data_dir = os.path.join(GLib.get_user_data_dir(), "vellum")
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(os.path.join(self.data_dir, "covers"), exist_ok=True)

        # Settings (library location, appearance) live in a plain JSON file.
        self.config_path = os.path.join(self.data_dir, "config.json")
        config: dict = {}
        if os.path.isfile(self.config_path):
            try:
                with open(self.config_path, "r", encoding="utf-8") as handle:
                    config = json.load(handle)
            except (OSError, ValueError) as exc:
                logger.warning(
                    "Ignoring unreadable config %s: %s", self.config_path, exc
                )
        self.config = config
        library_path = self.config.get("library_path") or os.path.join(
            self.data_dir, "library.db"
        )
        changed = False
        if self.config.get("library_path") != library_path:
            self.config["library_path"] = library_path
            changed = True
        if self.config.get("color_scheme") not in ("system", "light", "dark"):
            self.config.setdefault("color_scheme", "system")
            changed = changed or "color_scheme" not in config
        if not self.config.get("accent_color"):
            self.config["accent_color"] = "blue"
            changed = True
        if not isinstance(self.config.get("show_hidden"), bool):
            self.config["show_hidden"] = False
            changed = True
        if changed:
            self.save_config()

        self.library = Library(library_path)
        try:
            self.library.open()
        except Exception as exc:
            # A configured library can disappear (removed USB drive,
            # unmounted network share, deleted folder). Never let that
            # prevent the app from starting.
            fallback = os.path.join(self.data_dir, "library.db")
            if os.path.realpath(fallback) == os.path.realpath(library_path):
                raise
            logger.error(
                "Could not open library %s (%s); using %s",
                library_path, exc, fallback,
            )
            self.library = Library(fallback)
            self.library.open()
            self.config["library_path"] = fallback
            self.save_config()
            self.startup_warning = (
                f"Could not open {library_path}; using the default library"
            )

        self.engine = MetadataEngine()
        self._register_builtin_sources()

        self.plugin_manager = PluginManager(
            self.engine, os.path.join(self.data_dir, "plugins")
        )
        try:
            self.plugin_manager.load_all()
        except Exception as exc:
            logger.warning("Plugin loading failed: %s", exc)

        # Store plugins (calibre store zips) are loaded separately from
        # metadata plugins; a broken store must never break startup.
        self.stores = []
        plugin_dir = os.path.join(self.data_dir, "plugins")
        try:
            from vellum.core.store import is_store_plugin, load_store_plugin

            for entry in sorted(os.listdir(plugin_dir)):
                if not entry.endswith(".zip"):
                    continue
                zip_path = os.path.join(plugin_dir, entry)
                try:
                    if not is_store_plugin(zip_path):
                        continue
                    adapter = load_store_plugin(zip_path)
                    if adapter is not None:
                        self.stores.append(adapter)
                except Exception as exc:
                    logger.warning(
                        "Failed to load store plugin %s: %s", zip_path, exc
                    )
        except Exception as exc:
            logger.warning("Store plugin setup failed: %s", exc)

        self._purge_legacy_demo_books()
        show_hidden_action = self.lookup_action("show-hidden")
        if show_hidden_action is not None:
            show_hidden_action.set_state(
                GLib.Variant("b", bool(self.config.get("show_hidden", False)))
            )

    def _register_builtin_sources(self) -> None:
        try:
            from vellum.metadata.sources import GoogleBooks, OpenLibrary

            self.engine.register_source(GoogleBooks())
            self.engine.register_source(OpenLibrary())
        except Exception as exc:
            logger.warning("Could not register metadata sources: %s", exc)

    def _purge_legacy_demo_books(self) -> None:
        """Delete the sample books that 0.1.0 seeded into new libraries."""
        if self.config.get("legacy_demo_books_purged"):
            return
        try:
            removed = self.library.delete_books_without_files(
                LEGACY_DEMO_TITLES
            )
        except Exception as exc:
            logger.warning("Could not purge legacy sample books: %s", exc)
            return
        self.config["legacy_demo_books_purged"] = True
        self.save_config()
        if removed:
            logger.info("Removed %d legacy sample books", removed)

    # -- config / appearance -----------------------------------------------------

    def save_config(self) -> None:
        try:
            with open(self.config_path, "w", encoding="utf-8") as handle:
                json.dump(self.config, handle, indent=2)
        except OSError as exc:
            logger.warning("Could not write config %s: %s", self.config_path, exc)

    def set_library_directory(self, dir_path: str) -> bool:
        """Switch the active library to ``<dir_path>/library.db``.

        Returns True on success, False if the directory is unusable or the
        new database cannot be opened. On any failure the previous library
        stays open and the config is left unchanged; the app state never
        ends up with a closed library.
        """
        window = self.get_active_window()
        try:
            os.makedirs(dir_path, exist_ok=True)
        except OSError:
            if window is not None:
                window.show_toast("Cannot use that directory")
            return False
        if not os.path.isdir(dir_path) or not os.access(dir_path, os.W_OK):
            if window is not None:
                window.show_toast("Cannot use that directory")
            return False

        new_db = os.path.join(dir_path, "library.db")
        if os.path.realpath(new_db) == os.path.realpath(self.library.path):
            return True

        old_library = self.library
        old_library.close()
        self.library = Library(new_db)
        try:
            self.library.open()
        except Exception:
            # Roll back: never leave the app without an open library.
            self.library = old_library
            try:
                self.library.open()
            except Exception as exc:
                logger.error("Failed to reopen old library: %s", exc)
            if window is not None:
                window.show_toast("Cannot use that directory")
            return False

        self.config["library_path"] = new_db
        self.save_config()

        if window is not None:
            window.library = self.library
            # StoreView captured the library at construction; keep it in sync.
            if getattr(window, "store_view", None) is not None:
                window.store_view._library = self.library
            window.refresh_library()
            window.show_toast(f"Library location changed to {dir_path}")
        return True

    def apply_appearance(self) -> None:
        scheme = self.config.get("color_scheme", "system")
        style_manager = Adw.StyleManager.get_default()
        style_manager.set_color_scheme(
            {
                "light": Adw.ColorScheme.FORCE_LIGHT,
                "dark": Adw.ColorScheme.FORCE_DARK,
            }.get(scheme, Adw.ColorScheme.PREFER_LIGHT)
        )

        accent = self.config.get("accent_color", "blue")
        if accent in ACCENTS:
            bg, fg = ACCENTS[accent]
        else:
            bg, fg = accent, "#ffffff"
        css = (
            ":root {"
            f" --accent-bg-color: {bg};"
            f" --accent-color: {bg};"
            f" --accent-fg-color: {fg};"
            " }\n"
            f"@define-color accent_bg_color {bg};\n"
            f"@define-color accent_color {bg};\n"
            f"@define-color accent_fg_color {fg};\n"
        )
        display = Gdk.Display.get_default()
        if display is None:
            return
        if self._accent_provider is None:
            self._accent_provider = Gtk.CssProvider()
            Gtk.StyleContext.add_provider_for_display(
                display,
                self._accent_provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
            )
        self._accent_provider.load_from_string(css)

    # -- actions -----------------------------------------------------------------

    def set_show_hidden(self, value: bool) -> None:
        """Show or hide books marked hidden and refresh the library grid."""
        self.config["show_hidden"] = bool(value)
        self.save_config()
        action = self.lookup_action("show-hidden")
        if action is not None:
            action.set_state(GLib.Variant("b", bool(value)))
        window = self.get_active_window()
        if window is not None:
            window.refresh_library()

    def _on_show_hidden(self, action, _param) -> None:
        self.set_show_hidden(not action.get_state().get_boolean())

    def _on_import_calibre(self, *_args) -> None:
        dialog = Gtk.FileDialog(
            modal=True, title="Choose Calibre Library Folder"
        )
        dialog.select_folder(
            self.get_active_window(),
            None,
            self._on_calibre_folder_chosen,
            dialog,
        )

    def _on_calibre_folder_chosen(self, dialog, result, _data=None) -> None:
        try:
            folder = dialog.select_folder_finish(result)
        except Exception:
            return  # cancelled or failed
        if folder is None:
            return
        path = folder.get_path()
        if path:
            self.import_calibre_folder(path)

    def import_calibre_folder(self, path: str) -> None:
        """Import a calibre library directory on a background thread."""
        from vellum.core.calibre import is_calibre_library

        window = self.get_active_window()
        if not is_calibre_library(path):
            if window is not None:
                window.show_toast("Not a calibre library (no metadata.db)")
            return
        if self._calibre_import_running:
            if window is not None:
                window.show_toast("A calibre import is already running")
            return
        self._calibre_import_running = True
        if window is not None:
            window.show_toast("Importing calibre library…")
        threading.Thread(
            target=self._calibre_import_worker, args=(path,), daemon=True
        ).start()

    def _calibre_import_worker(self, path: str) -> None:
        from vellum.core.calibre import import_calibre_library

        try:
            result = import_calibre_library(self.library, path)
        except Exception as exc:
            logger.exception("Calibre import failed")
            GLib.idle_add(self._calibre_import_done, None, str(exc))
        else:
            GLib.idle_add(self._calibre_import_done, result, None)

    def _calibre_import_done(self, result, error) -> bool:
        self._calibre_import_running = False
        window = self.get_active_window()
        if error is not None:
            if window is not None:
                window.show_toast(f"Calibre import failed: {error}")
            return False
        if window is not None:
            # StoreView captured the library at construction; keep it in sync.
            if getattr(window, "store_view", None) is not None:
                window.store_view._library = self.library
            window.refresh_library()
            parts = [
                f"Imported {result.added} calibre "
                f"{'book' if result.added == 1 else 'books'}"
            ]
            if result.skipped:
                parts.append(f"{result.skipped} already present")
            if result.failed:
                parts.append(f"{result.failed} failed")
            window.show_toast(" · ".join(parts))
        return False

    def _on_preferences(self, *_args) -> None:
        from vellum.ui.preferences import PreferencesDialog

        dialog = PreferencesDialog(self)
        dialog.present(self.get_active_window())

    def _on_about(self, *_args) -> None:
        parent = self.get_active_window()
        if hasattr(Adw, "AboutDialog"):
            dialog = Adw.AboutDialog(
                application_name=APP_NAME,
                application_icon=APP_ID,
                version=__version__,
                developer_name="Vellum developers",
                license_type=Gtk.License.GPL_3_0,
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
                license_type=Gtk.License.GPL_3_0,
                comments="A calibre-like ebook library manager.",
            )
            about_window.present()


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO)
    app = VellumApplication()
    return app.run(sys.argv if argv is None else list(argv))


if __name__ == "__main__":
    raise SystemExit(main())

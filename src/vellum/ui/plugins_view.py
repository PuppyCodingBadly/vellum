"""Plugin management page."""

from __future__ import annotations

import logging
import os
import shutil

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk

logger = logging.getLogger(__name__)


class PluginsView(Gtk.Box):
    """Lists loaded plugins and allows adding/removing them."""

    def __init__(self, manager, window):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self._manager = manager
        self._window = window

        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        top.set_margin_top(18)
        top.set_margin_bottom(6)
        top.set_margin_start(18)
        top.set_margin_end(18)
        heading = Gtk.Label(label="Installed Plugins", xalign=0, hexpand=True)
        heading.add_css_class("title-3")
        top.append(heading)
        add_button = Gtk.Button(label="Add Plugin…")
        add_button.add_css_class("suggested-action")
        add_button.connect("clicked", self._on_add_clicked)
        top.append(add_button)
        self.append(top)

        self._stack = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True
        )

        scrolled = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        self._list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self._list.add_css_class("boxed-list")
        self._list.set_margin_top(12)
        self._list.set_margin_bottom(18)
        self._list.set_margin_start(18)
        self._list.set_margin_end(18)
        scrolled.set_child(self._list)
        self._stack.add_named(scrolled, "list")

        empty = Adw.StatusPage(
            title="No Plugins Installed",
            description="Add a plugin archive (.zip) to extend Vellum.",
            icon_name="application-x-addon-symbolic",
            vexpand=True,
        )
        self._stack.add_named(empty, "empty")

        self.append(self._stack)
        self.refresh()

    # -- public API ---------------------------------------------------------

    def refresh(self) -> None:
        while (child := self._list.get_first_child()) is not None:
            self._list.remove(child)

        try:
            plugins = self._manager.loaded()
        except Exception as exc:  # defensive: never break the page
            logger.warning("Failed to list plugins: %s", exc)
            plugins = []

        for info in plugins:
            self._list.append(self._build_row(info))

        stores = list(getattr(self._window, "stores", []) or [])
        for store in stores:
            self._list.append(self._build_store_row(store))

        self._stack.set_visible_child_name(
            "list" if plugins or stores else "empty"
        )

    def _build_store_row(self, store) -> Adw.ActionRow:
        name = str(getattr(store, "name", "") or "Unnamed store")
        description = str(getattr(store, "description", "") or "")
        subtitle = f"Store plugin · {description}" if description else "Store plugin"
        return Adw.ActionRow(title=name, subtitle=subtitle)

    # -- internals ----------------------------------------------------------

    def _build_row(self, info: dict) -> Adw.ActionRow:
        name = str(info.get("name", ""))
        version = str(info.get("version", ""))
        description = str(info.get("description", ""))
        subtitle = f"v{version} · {description}" if version else description
        row = Adw.ActionRow(title=name or "Unnamed plugin", subtitle=subtitle)

        remove = Gtk.Button(
            icon_name="user-trash-symbolic",
            tooltip_text="Remove plugin",
            valign=Gtk.Align.CENTER,
        )
        remove.add_css_class("flat")
        remove.connect("clicked", self._on_remove_clicked, name)
        row.add_suffix(remove)
        return row

    def _on_remove_clicked(self, _button: Gtk.Button, name: str) -> None:
        try:
            self._manager.unload(name)
        except Exception as exc:
            self._toast(f"Failed to remove '{name}': {exc}")
            return
        self._toast(f"Removed plugin '{name}'")
        self.refresh()

    def _on_add_clicked(self, _button: Gtk.Button) -> None:
        dialog = Gtk.FileDialog(title="Add Plugin")
        zip_filter = Gtk.FileFilter(name="Plugin archives (*.zip)")
        zip_filter.add_pattern("*.zip")
        filters = Gio.ListStore(item_type=Gtk.FileFilter)
        filters.append(zip_filter)
        dialog.set_filters(filters)
        dialog.set_default_filter(zip_filter)
        dialog.open(self._window, None, self._on_file_chosen)

    def _on_file_chosen(self, dialog: Gtk.FileDialog, result) -> None:
        try:
            gfile = dialog.open_finish(result)
        except GLib.Error:
            return  # dismissed by the user
        path = gfile.get_path() if gfile is not None else None
        if not path:
            self._toast("Only local plugin files are supported")
            return

        from vellum.core.store import is_store_plugin, load_store_plugin

        if is_store_plugin(path):
            dest = os.path.join(
                self._manager.plugin_dir, os.path.basename(path)
            )
            try:
                if os.path.abspath(path) != os.path.abspath(dest):
                    shutil.copy2(path, dest)
                adapter = load_store_plugin(dest)
            except Exception as exc:
                self._toast(f"Failed to load store plugin: {exc}")
                return
            if adapter is None:
                self._toast("Failed to load store plugin")
                return
            self._window.add_store(adapter)
            self._toast(
                f"Loaded store plugin '{adapter.name}' — see Get Books"
            )
            self.refresh()
            return

        try:
            name = self._manager.load(path)
        except Exception as exc:
            self._toast(f"Failed to load plugin: {exc}")
            return
        self._toast(f"Loaded plugin '{name}'")
        self.refresh()

    def _toast(self, message: str) -> None:
        show = getattr(self._window, "show_toast", None)
        if callable(show):
            show(message)
        else:
            logger.info("Toast: %s", message)

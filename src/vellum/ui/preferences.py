"""Preferences dialog: appearance (color scheme + accent color)."""

from __future__ import annotations

import os

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, Gtk

from vellum.app import ACCENTS

SWATCH_CSS = """
.accent-swatch {
    min-width: 40px;
    min-height: 40px;
    border-radius: 999px;
    padding: 0;
}
.accent-swatch:checked {
    box-shadow: 0 0 0 3px @window_bg_color, 0 0 0 5px currentColor;
}
"""


class PreferencesDialog(Adw.PreferencesDialog):
    def __init__(self, application):
        super().__init__(title="Preferences")
        self.app = application

        provider = Gtk.CssProvider()
        provider.load_from_string(SWATCH_CSS + self._palette_css())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        page = Adw.PreferencesPage()
        self.add(page)

        library_group = Adw.PreferencesGroup(title="Library")
        page.add(library_group)

        self._library_row = Adw.ActionRow(title="Library directory")
        self._library_row.set_subtitle(self._current_library_dir())
        choose_button = Gtk.Button(label="Choose…", valign=Gtk.Align.CENTER)
        choose_button.connect("clicked", self._on_choose_library)
        self._library_row.add_suffix(choose_button)
        self._library_row.set_activatable_widget(choose_button)
        library_group.add(self._library_row)

        group = Adw.PreferencesGroup(title="Appearance")
        page.add(group)

        # Color scheme
        schemes = ["system", "light", "dark"]
        self._scheme_row = Adw.ComboRow(
            title="Color scheme",
            model=Gtk.StringList.new(["System", "Light", "Dark"]),
        )
        current = self.app.config.get("color_scheme", "system")
        self._scheme_row.set_selected(
            schemes.index(current) if current in schemes else 0
        )
        self._scheme_row.connect("notify::selected", self._on_scheme, schemes)
        group.add(self._scheme_row)

        # Accent color swatches
        accent_row = Adw.PreferencesRow(title="Accent color", activatable=False)
        flow = Gtk.FlowBox(
            max_children_per_line=10,
            selection_mode=Gtk.SelectionMode.NONE,
            homogeneous=True,
            row_spacing=8,
            column_spacing=8,
            margin_top=6,
            margin_bottom=6,
        )
        accent_row.set_child(flow)
        group.add(accent_row)

        self._swatches: dict[str, Gtk.ToggleButton] = {}
        group_leader = None
        for name in ACCENTS:
            button = Gtk.ToggleButton(css_classes=["accent-swatch", f"accent-{name}"])
            button.set_tooltip_text(name.capitalize())
            if group_leader is None:
                group_leader = button
            else:
                button.set_group(group_leader)
            button.connect("toggled", self._on_accent_toggled, name)
            self._swatches[name] = button
            flow.append(button)

        # Custom color as a 10th swatch
        if hasattr(Gtk, "ColorDialogButton"):
            dialog = Gtk.ColorDialog(with_alpha=False)
            self._color_button = Gtk.ColorDialogButton(
                dialog=dialog, css_classes=["accent-swatch", "accent-custom"]
            )
        else:
            self._color_button = Gtk.ColorButton(
                css_classes=["accent-swatch", "accent-custom"]
            )
        self._color_button.set_tooltip_text("Custom color")
        self._color_button.connect("notify::rgba", self._on_custom_color)
        flow.append(self._color_button)

        reader_group = Adw.PreferencesGroup(title="Reader")
        page.add(reader_group)

        self._animation_row = Adw.SwitchRow(
            title="Page turn animation",
            subtitle="Slide between pages (disable on low-end hardware)",
        )
        self._animation_row.set_active(
            self.app.config.get("reader_animation", True)
        )
        self._animation_row.connect("notify::active", self._on_animation_toggled)
        reader_group.add(self._animation_row)

        self._sync_accent_ui()

    # -- helpers -----------------------------------------------------------------

    def _current_library_dir(self) -> str:
        return os.path.dirname(self.app.config["library_path"])

    def _on_choose_library(self, _button) -> None:
        dialog = Gtk.FileDialog(modal=True, title="Choose Library Directory")
        try:
            dialog.set_initial_folder(
                Gio.File.new_for_path(self._current_library_dir())
            )
        except Exception:
            pass
        dialog.select_folder(self.get_root(), None, self._on_folder_chosen, dialog)

    def _on_folder_chosen(self, dialog, result, _data) -> None:
        try:
            folder = dialog.select_folder_finish(result)
        except Exception:
            return  # cancelled or failed; subtitle stays unchanged
        if folder is None:
            return
        path = folder.get_path()
        if path is None:
            return
        if self.app.set_library_directory(path):
            self._library_row.set_subtitle(path)

    @staticmethod
    def _palette_css() -> str:
        rules = []
        for name, (bg, fg) in ACCENTS.items():
            rules.append(
                f".accent-swatch.accent-{name} {{ background: {bg}; color: {fg}; }}"
            )
        return "\n".join(rules)

    def _sync_accent_ui(self) -> None:
        accent = self.app.config.get("accent_color", "blue")
        for name, button in self._swatches.items():
            button.handler_block_by_func(self._on_accent_toggled)
        for name, button in self._swatches.items():
            button.set_active(name == accent)
        for name, button in self._swatches.items():
            button.handler_unblock_by_func(self._on_accent_toggled)
        if accent not in ACCENTS:
            rgba = Gdk.RGBA()
            if rgba.parse(accent):
                self._color_button.set_rgba(rgba)

    # -- callbacks -----------------------------------------------------------------

    def _on_animation_toggled(self, row, _param) -> None:
        self.app.config["reader_animation"] = row.get_active()
        self.app.save_config()

    def _on_scheme(self, row, _param, schemes) -> None:
        self.app.config["color_scheme"] = schemes[row.get_selected()]
        self.app.save_config()
        self.app.apply_appearance()

    def _on_accent_toggled(self, button, name) -> None:
        if not button.get_active():
            return
        self.app.config["accent_color"] = name
        self.app.save_config()
        self.app.apply_appearance()

    def _on_custom_color(self, button, _param) -> None:
        rgba = button.get_rgba()
        if rgba is None:
            return

        def clamp(value: float) -> int:
            return max(0, min(255, round(value * 255)))

        self.app.config["accent_color"] = (
            f"#{clamp(rgba.red):02x}{clamp(rgba.green):02x}{clamp(rgba.blue):02x}"
        )
        self.app.save_config()
        self.app.apply_appearance()
        self._sync_accent_ui()

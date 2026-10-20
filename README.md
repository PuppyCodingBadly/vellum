# Vellum

Vellum is a calibre-inspired ebook library manager with a modern
GTK4/Libadwaita interface. It organizes your ebook collection in a local
SQLite library, supports calibre metadata-source plugins out of the box,
and can look up book metadata (title, authors, covers, descriptions) from
online sources such as Google Books and OpenLibrary.

## Features

- Modern GTK4/Libadwaita user interface
- SQLite-backed book library (authors, tags, formats, ratings, covers)
- Fast full-text-ish search across titles, authors, ISBNs, and tags
- Online metadata lookup with per-source result merging and cover downloads
- Compatibility with calibre metadata-source plugins (drop in the `.zip`)
- Import books from your Documents folder when running as a Flatpak

## Quick start (development)

Vellum needs the system GTK4/Libadwaita Python bindings (PyGObject). Install
them via your distro, e.g.:

- Fedora: `sudo dnf install python3-gobject gtk4 libadwaita`
- Debian/Ubuntu: `sudo apt install python3-gi gir1.2-gtk-4.0 gir1.2-adw-1`

Then, from the repository root:

```sh
pip install -e .
python -m vellum.app
```

(`pip install -e .` installs the `src/`-layout package and the `vellum`
console script; `python -m vellum.app` runs the app entry point directly.)

## Flatpak

Build and install locally:

```sh
flatpak-builder --user --install --force-clean build flatpak/io.github.vellum.Vellum.yml
flatpak run io.github.vellum.Vellum
```

The manifest targets the GNOME 48 runtime; see the comment at the top of
`flatpak/io.github.vellum.Vellum.yml` if you only have 47 available.

> **Icon:** the desktop file and metainfo reference the icon name
> `io.github.vellum.Vellum`, but a real icon file is a TODO placeholder —
> no icon binary ships yet.

## Plugins

Vellum can load calibre metadata-source plugins. On the **Plugins** page in
the app, drop a calibre metadata-source plugin `.zip` and it will be
installed and registered as a metadata source automatically. Loaded plugins
can be removed from the same page.

## Project layout

```
vellum/
├── data/                     # desktop entry + AppStream metainfo
├── flatpak/                  # Flatpak manifest
├── src/vellum/
│   ├── app.py                # application entry point (main)
│   ├── core/                 # Book/Author models, SQLite library
│   ├── metadata/             # metadata engine + online sources
│   │   └── sources/
│   ├── plugins/              # calibre plugin compatibility + manager
│   └── ui/                   # GTK4/Libadwaita user interface
└── tests/
```

## Roadmap

- OPDS / device sync support
- Ebook format conversion pipeline
- Full-text search over book contents
- Reading statistics and shelves/collections
- Publish on Flathub (with a proper app icon)

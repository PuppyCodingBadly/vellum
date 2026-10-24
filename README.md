# Vellum

> **Contributors/agents: see [ACTION_PLAN.md](ACTION_PLAN.md) — the prioritized, executable improvement plan for this repo.**

Vellum is a calibre-inspired ebook library manager for Linux desktop. It keeps the
catalogue in a local SQLite database, reads EPUB, MOBI, and PDF books, and
looks up metadata and covers from several online sources.

## Install

```sh
flatpak install --user https://puppycodingbadly.github.io/vellum/io.github.vellum.Vellum.flatpakref
flatpak run io.github.vellum.Vellum
```

Updates: `flatpak update io.github.vellum.Vellum`.


## Features

- Library grid with 2:3 cover tiles, search, and sorting by title, author,
  rating, or recently added
- Library metadata search (title, authors, tags, ISBN) plus full-text search
  across book contents, with chapter-level results
- SQLite catalogue: books, authors, tags, formats, ratings, covers,
  highlights, reading positions, shelves, and reading sessions
- Metadata lookup from Google Books, Open Library, Internet Archive, Library
  of Congress, and Inventaire, with result merging, fuzzy query ranking, and
  cover fetch
- Universal metadata grabber for pasted book-page URLs (JSON-LD, OpenGraph,
  and microdata)
- EPUB/MOBI/PDF reader with:
  - adjustable font size for EPUB and MOBI, and font-scaled PDF page rendering
  - Light, Sepia, and Dark themes (or follow the system scheme)
  - table of contents, page/chapter turns, swipe gestures, and fullscreen
  - text highlights with a highlights panel (EPUB/MOBI)
  - in-reader dictionary lookup
  - automatic reading-position resume
  - reading-session tracking
- Shelves/collections with searchable book picker
- Reading statistics (total time, books read, sessions, per-book totals)
- Preferences for library directory, accent color, color scheme, hidden
  books, and reader animation
- Calibre library import from a `metadata.db` folder
- Calibre metadata-source and store plugins through a bundled Python sidecar
- "Get Books" store search and download into the current library
- Show/hide books, standard window shortcuts (Ctrl+F, Alt+Left, F11, Ctrl+Q),
  and a title bar that follows the app's light/dark theme

## Requirements

- Flutter 3.35+ with Linux desktop support (Dart 3.9+)
- `clang`, `cmake`, `ninja`, `pkg-config`, and GTK 3 development headers
- Python 3 for the plugin sidecar
- PDFium (optional; see below)

## Run

```sh
flutter pub get
flutter run -d linux
```

For a build:

```sh
flutter build linux --release
./build/linux/x64/release/bundle/vellum
```

### PDF support

PDF pages are rendered with PDFium through `package:pdfium_dart`. The loader
looks for a shared library in this order:

1. `$PDFIUM_PATH`
2. `$HOME/.local/share/vellum-flutter/pdfium/lib/libpdfium.so`
3. `libpdfium.so` on the system library path

A Linux x64 build can be placed at the second path with:

```sh
mkdir -p ~/.local/share/vellum-flutter/pdfium
curl -sSL https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-linux-x64.tgz \
  | tar -xz -C ~/.local/share/vellum-flutter/pdfium
```

### Flatpak

The Flatpak packages a prebuilt Linux release bundle, so the Flatpak build
itself does not need the Flutter SDK or network access:

```sh
./tool/build-flatpak.sh
```

This runs `flutter build linux --release`, stages `build/`, `sidecar/`, and
`data/` into `flatpak/`, and exports a signed local repository under
`build/flatpak-repo`. Set `FLATPAK_GPG_KEY` and `FLATPAK_GPG_HOME` to sign a
repository for publishing.

## Tests

```sh
PDFIUM_PATH=$HOME/.local/share/vellum-flutter/pdfium/lib/libpdfium.so \
  flutter test
flutter analyze
python3 -m pytest sidecar/tests -q
```

The UI smoke tests cover navigation, library/content search, details, the
reader, shelves, plugins/store empty states, live reading statistics, and font
scaling for EPUB, MOBI, and PDF.

## Data locations

- Config and library: `$XDG_DATA_HOME/vellum` (default
  `~/.local/share/vellum`), with `config.json` and `library.db`
- Covers and thumbnails: `<data>/covers`
- Plugins: `<data>/plugins`
- Reader cache: `$XDG_CACHE_HOME/vellum/reader/...` (default
  `~/.cache/vellum/reader`)

## Plugins

Metadata-source and store plugins are calibre `.zip` archives loaded by a
local Python sidecar (`sidecar/main.py`) and exposed to Dart over JSON-RPC on
stdio. Install them from the Plugins page. Calibre GUI action plugins are not
supported. The Flatpak bundles the libraries common metadata and store plugins
import (`lxml`, `six`, `beautifulsoup4`, `html5lib`, `requests`).

## Project layout

```
lib/
├── main.dart                 application bootstrap and window setup
├── app_state.dart            shared library/theme/reader state
├── core/                     models, SQLite library, config, covers, sorting
├── formats/                  EPUB, MOBI, PDF, dictionary, HTML text extraction
├── import/                   file and calibre-library import
├── metadata/                 metadata engine, sources, URL grabber, sorting
├── plugins/                  Python sidecar client and plugin controller
├── store/                    store downloads
├── fts/                      full-text indexer
├── stats/                    reading-session tracking
├── reader/                   reader controller and document model
└── ui/                       pages, dialogs, and shared widgets
linux/runner/                 GTK runner, including title-bar theme channel
sidecar/                      Python calibre plugin compatibility layer
test/                         Dart tests, including UI smoke tests
data/                         desktop entry, AppStream metadata, icons
flatpak/                      Flatpak manifest, bundled PDFium, staging script
tool/                         release and Flatpak build scripts
docs/inventory/               porting contracts from the original application
```

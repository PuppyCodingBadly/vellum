# Vellum UI slice — implementation contract (GTK4/libadwaita → Flutter)

Original source (authoritative, readable): /tmp/vellum/src/vellum/app.py and /tmp/vellum/src/vellum/ui/*.py

## 0. Application shell (app.py)
- application_id "io.github.vellum.Vellum", name "Vellum", version 0.1.20, GPL-3.0, "A calibre-like ebook library manager."
- Config: plain JSON at `~/.local/share/vellum/config.json`. Keys (defaults): library_path (default `<data_dir>/library.db`), color_scheme ∈ {system(default), light, dark}, accent_color ("blue" default; palette name or #rrggbb), show_hidden (false), sort_key (∈ SORT_KEYS, default "title"), reader_animation (true), reader_font_scale (0.8–1.6, default 1.0), reader_theme ("follow" default), legacy_demo_books_purged (one-shot). Saved on every change.
- Accent palette (name → bg/fg): blue #3584e4/#fff, teal #2190a4, green #3a944a, yellow #c88800, orange #ed5b00, red #e62d42, pink #d56199, purple #9141ac, slate #6f8396 (all fg #ffffff). Custom accent = any #rrggbb, white fg.
- Data dir `~/.local/share/vellum/` (+ covers/, plugins/); fallback to default db with toast "Could not open {path}; using the default library".
- Metadata sources registered: GoogleBooks, OpenLibrary, InternetArchive, LibraryOfCongress, Inventaire (English-only). PluginManager loads calibre plugin zips from <data_dir>/plugins; store zips loaded separately.
- Legacy purge: first run deletes books with empty path whose title ∈ {"The Left Hand of Darkness","Pride and Prejudice","The Hobbit","Clean Code","Dune"}.
- Calibre import: FileDialog "Choose Calibre Library Folder" → validate metadata.db (toast "Not a calibre library (no metadata.db)") → background import, toasts "Importing calibre library…" then "Imported N calibre book(s) · M already present · K failed: <first error, truncated 140>". Re-entrant guard "A calibre import is already running".
- About: name Vellum, GPL-3.0, comments "A calibre-like ebook library manager."
- Actions: app.about, app.preferences, app.quit (Ctrl+Q), app.show-hidden (boolean), app.import-calibre, app.toggle-fullscreen (F11).
- Menu: Preferences, "Import Calibre Library…", "Show Hidden Books", "Fullscreen (F11)", "About Vellum", "Close Window", "Quit".

## 1. Window & navigation (window.py)
- Title "Vellum". Initial size ~1100×750 fitted. Root: ToastOverlay → page Stack (explicit back buttons; popped pages kept alive).
- Root page header: start = ViewSwitcher (tabs), center = SearchEntry placeholder "Search library…", end = sort DropDown (tooltip "Sort library") + MenuButton.
- Tabs: "Library" (view-grid-symbolic), "Get Books" (folder-download-symbolic), "Plugins" (application-x-addon-symbolic).
- Shortcuts: Ctrl+F → Library tab + focus search; Alt+Left → pop page.
- Pushed pages: header with back button ("Back") + centered ellipsized title.
- show_toast(msg): 3 s toast.
- Search: 300 ms debounce; library.search(query, include_hidden); empty → all_books; sorted with sort_books(current key).
- refresh_library() re-reads config["show_hidden"]. Sort dropdown persists config["sort_key"].

### Search semantics (db.py)
Tokens AND; per-token case-insensitive LIKE %token% on title, ISBN, author name, tag name. Hidden excluded unless include_hidden.

### Sort modes (sorting.py)
("title","Title"),("author","Author"),("rating","Rating"),("added","Recently added"). Author: joined casefold, empty sorts last (\uffff), tie title. Rating desc tie title. Added desc (undated last by title). Unknown → title.

## 2. Library grid (library_view.py)
- Scrolled GridView, margins 12.
- Card: 160×240, aspect 2:3, rounded 8 frame → cover image (fit cover) OR placeholder with initials (first letters of first 2 title words uppercase, "?" if none; accent bg, white bold 32). Caption overlay at bottom: gradient black 0.82→transparent, title (ellipsized, max 22 chars, white w/ shadow) + authors (max 24 chars, ", " joined or "Unknown author", white 82%). Tooltip = title + "\n" + authors. Hidden books opacity 0.55.
- Thumbnails: cached via thumb_cache_path/thumb_path; valid if mtime ≥ source; background worker; failure falls back to source cover.
- Tap → book details page.

## 3. Book details (book_details.py)
- Pushed page; scroll, clamp 780, spacing 24, margins 24.
- Header: cover 220×330 2:3 (or placeholder) + right column: title (large), authors (dim), rating "★★★★☆  4.2" (5 stars rounded from rating; numeric only if rating truthy), tag chips (accent 15% bg, accent text, pill; hidden if none).
- Buttons: "Fetch Metadata" (primary) → MetadataDialog; "Read" (primary, only if formats ∩ {epub,pdf,mobi} non-empty and book.path exists) → ReaderPage; "Hide Book"/"Unhide Book" toggle → set_hidden, toast "Book hidden"/"Book shown", refresh grid.
- Details group rows: Publisher, Published, Language, ISBN — hidden when empty.
- Description heading + selectable label, fallback "No description available."

## 4. Preferences (preferences.py)
One page:
**Library**: "Library directory" row (subtitle current dir) + "Choose…" → validate writable, swap to <dir>/library.db with rollback (toast "Cannot use that directory"), persist library_path, toast "Library location changed to {dir}". "Import calibre library" ("Add books from a folder containing metadata.db") + "Import…" → app.import-calibre. "Show hidden books" switch ("Hidden books stay in the library but are left out of the grid").
**Appearance**: "Color scheme" System/Light/Dark → config color_scheme. "Accent color": 9 circular swatches (40×40, checked ring) + custom color picker → config accent_color, applies immediately.
**Reader**: "Page turn animation" switch ("Slide between pages (disable on low-end hardware)") → reader_animation (default true).

## 5. Metadata dialog (metadata_dialog.py)
Dialog "Fetch Metadata" 620×580. Header: title + "Apply" (primary, insensitive until selection; "Applying…" during) + close.
Body:
1. Query bar: SearchEntry "Search metadata by title, author, or ISBN…" + "Search" + result-sort DropDown (tooltip "Sort results"). Sort options: Relevance (default, engine order), Title, Author, Rating, Newest (pubdate desc); source_id=="merged" row pinned first.
2. URL bar: Entry "Paste a book page URL…" + "Grab". Non-URL input falls back to fuzzy query. Toasts: "Enter a title, author, or ISBN to search" / "Paste a book page URL first".
3. Stack: busy (spinner + "Searching metadata sources…" or "Reading book page…"), results (list, single selection), empty (StatusPage: "No Results"/"No metadata source returned a match."/"…matched that string."; "No Metadata Found"/"The page did not contain recognizable book metadata."; errors "Search Failed"/"Grab Failed" also toasted).
Flow: on present auto-search engine.find_all(title, authors, isbn). Free-form → find_query (ISBN-like by ISBN). URL grab → grab_url, single auto-selected result.
Result rows: 48×72 2:3 cover preview (fetched async, per-URL cache), title ("Untitled"), authors dim ("Unknown author"), origin "<source> · ISBN <isbn>", trailing "★ 4.2" if rated.
Apply: copy non-empty fields onto book (title, authors, isbn, publisher, pubdate, language, description, tags; rating only if truthy), download cover to <data_dir>/covers/{book.id}.jpg (best-effort, failure toasted but apply proceeds), update_book, toast "Metadata applied", refresh, close.

## 6. Plugins page (plugins_view.py)
- Header: "Installed Plugins" + "Add Plugin…" (primary).
- Empty: StatusPage "No Plugins Installed"/"Add a plugin archive (.zip) to extend Vellum."/application-x-addon-symbolic.
- Rows: metadata plugins "v{version} · {description}" + trash button ("Remove plugin") → unload + toast "Removed plugin '{name}'". Store plugins: subtitle "Store plugin · {description}", no remove.
- Add flow: FileDialog filter *.zip → if is_store_plugin: copy into <data_dir>/plugins/, load_store_plugin, toast "Loaded store plugin '{name}' — see Get Books"; else manager.load, toast "Loaded plugin '{name}'". Failures toasted.

## 7. Get Books / store (store_view.py)
- No stores → StatusPage "No store plugins"/"Add a calibre store plugin zip from the Plugins page"/folder-download-symbolic.
- Search bar: SearchEntry "Search stores…" (activate triggers), store-picker DropDown (>1 store only), "Search" primary, spinner. Empty query ignored; concurrent searches blocked.
- Results: rows title ("Untitled"), author dim, format chips + store name, per-row "Download".
- Initial status "Search for books"/"Enter a query above to find books available for download."/system-search-symbolic; empty results "No results"/"Try a different query or store."
- Download flow: spinner → fetch_download (toast "Could not resolve download link" if none) → stream download (64KiB chunks, 120s) to <data_dir>/downloads/{safe_title}.{ext} (ext = first format sanitized [a-z0-9] else "epub"; filename [^\w\-. ] removed, ≤80 chars, dedup "name (N).ext") → import_path into library resolved at import time → toasts "Added {title} to library", "Added {title} to the previous library" if switched mid-download, "Downloaded {title}" if no ids. Errors: "Download failed: {e}", "Import failed: {e}".

## 8. Reader (reader_view.py) — full detail
Opened via push ReaderPage(book, data_dir, library).
### Format selection & opening
- _primary_format: first of epub → pdf → mobi in book.formats (lowercased); default epub.
- EPUB: EpubBook.chapters() → items [(key,title)], extracted to cache dir. MOBI: MobiBook.sections() → HTML per section. Empty → "epub/mobi has no readable chapters/sections".
- PDF: page render at scale 1.75 × font_scale; TOC = page label or "Page N". Missing support → error page.
- Open failure → StatusPage "Cannot Open Book"/"This book file is not valid or is corrupted."/dialog-error-symbolic.
- Cache dir: <cache>/vellum/reader/<sha1("{id}:{path}:{mtime_ns}:{size}")[:16]>.
### Chrome (header)
Prev ("Previous"), Next ("Next"), item title centered ellipsized, counter ("Page 3 / 120" pdf, "Section 2 / 30" mobi, "2 / 30" epub), font-down ("Decrease font size"), font-up ("Increase font size"), "Chapters" menu (TOC), highlights menu (EPUB/MOBI only), theme menu, fullscreen ("Toggle fullscreen (F11)").
### Themes
Radio: Follow System / Light / Sepia / Dark → config reader_theme ∈ {follow, light, sepia, dark}; "follow" tracks app dark mode live. Colors: light (bg #ffffff, fg #1a1a1a), sepia (bg #f4ecd8, fg #5b4636), dark (bg #1e1e1e, fg #e8e8e8, link #8ab4f8). Layout CSS equivalent: max-width 46em, margin 1em auto, padding 0 1em, line-height 1.15, font-size scale*100%, img max-width 100%.
### Font size
reader_font_scale 0.8–1.6 step 0.1, persisted; PDF re-renders with scale multiplier. PDF zoom Ctrl+= / Ctrl+-, scale 1.0–3.0 step 0.25 (PDF only).
### Content & page-turn animation
- Slide transition forward/back, 200 ms; NONE when reader_animation false.
- PDF: LRU cache of rendered pages, cap 3; prefetch current ±1 off-thread; stale renders dropped.
### Keys & gestures
- Left arrow → prev, Right arrow → next. PDF zoom Ctrl+plus/equal, Ctrl+minus.
- Swipe: |vx| ≥ 250 px/s and |vx| ≥ 1.5×|vy|; left → next, right → prev.
- F11 → toggle fullscreen.
### Selection offsets (Dart port)
Python used WebKit JS bridge with character offsets into body.textContent (TreeWalker). Dart port: compute offsets over the concatenated plain text of the chapter document model; same locator formats.
### Highlights
- Colors: yellow #f2d94e, green #a8e6a3, pink #f7b6d2.
- Selecting text (EPUB/MOBI) → 350 ms debounce → popover at cursor: "Highlight", 3 color-dot buttons, flat "Define" button.
- Save: library.add_highlight(book_id, position_json, color, text); position = {"chapter": index, "start": int, "end": int, "quote": text[:200]}; apply visually; clear selection. Failure toast "Could not save highlight".
- Highlights panel (menu, refreshed on show): "No highlights yet" dim, else rows: colored dot + quote (≤120 chars, tooltip "Jump to highlight" → navigate chapter + scroll offset to ⅓ viewport) + trash ("Delete highlight" → delete, unmark, refresh). Max 380×400.
- Highlights re-applied on every chapter load.
### Dictionary
- "Define" takes first [A-Za-z][A-Za-z'\-]* word of selection → dictionary.lookup (dictionaryapi.dev 8s timeout, Wiktionary REST fallback). Normalized {word, phonetic, meanings:[{partOfSpeech, definitions}]} ≤3×3.
- Result dialog (420×420, title=word): word large, phonetic dim, per-meaning part-of-speech heading + "• definition" selectable. No match → toast "No definition found".
### Position save/resume
- Locator "<kind>:<index>:<fraction>" (fraction = scroll fraction 4 decimals clamped 0–1); set/get_reading_position. epub/mobi restore pending scroll after load; pdf restores page index only.
- Writes: every navigation; scroll coalesced ≥1s + trailing flush; final flush on close.
### Bottom progress bar
4px bar at page bottom: fraction = (current item index + 1) / item count.

## 9. Notes
- Roadmap features to ADD in the port (user-approved): shelves/collections, reading statistics, full-text search over book contents.
- Flatpak/packaging out of scope for the port (Linux desktop dev build only).

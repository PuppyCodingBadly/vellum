# Vellum — Action Plan (executable)

**Repo:** `/tmp/vellum-flutter` (clone of `github.com/PuppyCodingBadly/vellum`, baseline commit `fdd403f`, version 0.2.2+1)
**Audience:** autonomous coding agent (DeepSeek). Every task below is self-contained: Target files, current behavior, required change, acceptance criteria. Execute phases in order; tasks within a phase are independent and may be parallelized.
**Stack facts:** Flutter 3.35+/Dart 3.9+, Linux desktop only, `package:sqlite3` is **synchronous FFI**, Python sidecar under `sidecar/` runs calibre plugins over JSON-lines stdio.

## Global rules

1. Work on a branch per phase: `fix/phase-N`. Do NOT commit to `master` directly.
2. After each phase run ALL gates and stop if red:
   - `flutter analyze` (zero new issues)
   - `flutter test`
   - `python3 -m pytest sidecar/tests`
3. Never silence a warning/exception to make a gate pass; fix the cause.
4. Keep public API changes consistent across callers; no compatibility shims.
5. Line numbers below reference commit `fdd403f`; if drifted, locate by symbol name.

---

## PHASE 0 — Observability first (blocks nothing, but do first; ~1 task)

### T0.1 Restore crash telemetry
- **Target:** `lib/main.dart`
- **Current:** `main()` calls `runApp` (line ~107) with no error zone; `crash.log` in the data dir only gets a startup marker. A production SIGTRAP on 2026-10-20 left no app-side trace.
- **Change:** Wrap the app in `runZonedGuarded`; install `FlutterError.onError` and `PlatformDispatcher.instance.onError`; append timestamped entries (stage markers + stack traces) to `<dataDir>/crash.log` (append mode, reuse existing log path convention from the old app: `~/.local/share/vellum/crash.log`). Add env kill-switches honored at startup: `VELLUM_X11=1` (force X11 via `GDK_BACKEND=x11`) and `LIBGL_ALWAYS_SOFTWARE=1` safe mode, applied before `windowManager` init at `main.dart:33-44`.
- **Acceptance:** Throwing from a button handler in a debug build appends a timestamped stack trace to `crash.log`; app keeps running. Gates green.

---

## PHASE 1 — P0 correctness / data-loss / crash fixes

### T1.1 Make `Library.close()` real; stop stale `Library` captures
- **Target:** `lib/core/db.dart:67-69`, `lib/app_state.dart:158-164`, `lib/reader/reader_controller.dart:124-128`
- **Current:** `close()` only disposes `:memory:` databases; file-backed connections leak on every library switch, and a captured `Library` (reader, `stats_page.dart:17` cache) keeps writing to the OLD database file after `switchLibraryDirectory`.
- **Change:** `close()` always calls `_db.dispose()` with a `_closed` guard; any method called after close throws `StateError`. In `AppState.switchLibraryDirectory`, defer/refuse the switch while a reader holds the old instance (or resolve `library` lazily per call in `ReaderController`). Dispose the `Library` in `AppState.dispose`.
- **Acceptance:** New test: switch library with an open reader → no writes land in the old db file; closing twice does not throw. Gates green.

### T1.2 Eliminate concurrent PDFium access
- **Target:** `lib/reader/reader_controller.dart:667-671` (`_renderPdfPage`), `lib/formats/pdf_book.dart:71-77`
- **Current:** when the worker-isolate render throws, the fallback calls `_pdf!.renderPage(...)` on the UI isolate while the worker may still be mid-render. PDFium is process-global and not thread-safe → segfault class.
- **Change:** Delete the UI-isolate fallback entirely; surface a render error state instead. ALL `FPDF_*` calls happen in the worker isolate. Call `FPDF_InitLibrary` once per isolate with matching destroy.
- **Acceptance:** grep confirms no `renderPage` call outside the worker path; opening a PDF, zooming, and navigating works; forced worker failure shows an error banner, not a crash. Gates green.

### T1.3 Cap PDF raster allocation
- **Target:** `lib/formats/pdf_book.dart:158-163`
- **Current:** width/height clamped only to `1 << 30` per dimension before `FPDFBitmap_Create` → crafted MediaBox or high zoom allocates GB-scale bitmaps → OOM/abort.
- **Change:** Reject when `width * height` exceeds a pixel budget (use 100 MP) BEFORE allocation; cap effective scale (zoom × fontScale × defaultScale) accordingly; return a typed error the reader can display.
- **Acceptance:** New unit test feeds a page box that would exceed 100 MP → render request fails with the typed error, no allocation. Gates green.

### T1.4 Fix sidecar restart state loss
- **Target:** `lib/plugins/sidecar_client.dart:216-233`, `lib/plugins/plugin_controller.dart:57-61`
- **Current:** `_onProcessExit` restarts the process and retries pending requests, but the new Python process has an empty plugin registry; `PluginController._started` stays `true` so `load_all` is never re-issued. After any sidecar crash all plugins silently vanish until app restart; retried metadata searches even "succeed" with empty results.
- **Change:** On process exit, notify listeners; `PluginController` resets `_started = false` and re-runs `load_all` for every known plugin dir before retrying pending requests.
- **Acceptance:** New integration test (extend `test/plugins/`): kill the sidecar mid-request → after respawn, previously loaded plugins answer queries without app restart. Gates green.

### T1.5 Close native handles deterministically
- **Target:** `lib/reader/reader_controller.dart:419-435` (dispose), `:788-827` (worker)
- **Current:** `dispose` never calls `_pdf?.close()` (no callsite exists anywhere); the worker's `PdfBook` is never closed because `Isolate.kill` doesn't run cleanup; every PDF session leaks an `FPDF_DOCUMENT`.
- **Change:** Call `_pdf?.close()` in `dispose`; send a `close` message to the worker, let it close its `PdfBook`, then kill. Add a timeout on worker close handshake.
- **Acceptance:** Open/close the same PDF 20× in a test: native memory stable (assert via handle count or document close log). Gates green.

---

## PHASE 2 — P1 performance spine (the "everything blocks the UI isolate" theme)

### T2.1 Move book parsing off the UI isolate
- **Target:** `lib/formats/epub.dart:29-34`, `lib/formats/mobi.dart:86`, `lib/import/importer.dart:25-26,126`, `lib/reader/reader_controller.dart:567-587`
- **Current:** whole-file sync reads + full zip decompression + HTML/XML parse on the UI isolate for open/import/chapter-turn. Zero uses of `Isolate.run`/`compute` in `lib/`.
- **Change:** Run parse/extract in `Isolate.run`, returning plain data (strings/bytes/maps) to the UI isolate. Add a file-size guard (reject >512 MB inputs with a typed error). Keep sqlite writes on the main isolate for now.
- **Acceptance:** Opening a 50 MB EPUB keeps the UI responsive (no multi-second freeze; verify via a widget test with a fake clock or manual smoke). Gates green.

### T2.2 Move cover thumbnailing off the UI thread; remove `statSync` from `build()`
- **Target:** `lib/core/covers.dart:48-90`, `lib/ui/widgets/book_cover.dart:60,73`
- **Current:** `thumbPath` does `decodeImage → copyResize → encodePng → sync write` on the UI isolate per grid cell (covers up to 25 MB); `File(coverPath).statSync()` runs in `build()` per cell per rebuild.
- **Change:** Run `thumbPath` via `Isolate.run`; fold the mtime/size cache-key probe into the background task so `build()` only consults an in-memory cache. Alternative allowed: use `Image.file(..., cacheWidth: 320, cacheHeight: 480)` and delete the manual pipeline if output quality is equal.
- **Acceptance:** Scrolling a 500-cover grid shows no decode jank (manual smoke); no `statSync`/`readAsBytesSync` remains in any `build()` path. Gates green.

### T2.3 Fix N+1 hydration; add indexes
- **Target:** `lib/core/db.dart:336-356` (`_rowToBook`), schema at `:71-151`
- **Current:** every `Book` row triggers 3 extra SELECTs (authors/tags/formats); schema has ZERO secondary indexes; `search()` uses unindexable `LIKE '%…%'` per token.
- **Change:** Hydrate with 3 batched `WHERE book_id IN (...)` queries merged in Dart (or one `GROUP_CONCAT` join). Add indexes: `books(hidden)`, `books(title COLLATE NOCASE)` or equivalent, `book_authors(book_id)`, `book_tags(book_id)`, `book_formats(book_id)`, `reading_sessions(book_id)`, `highlights(book_id)`. Escape `%`/`_`/`\` in catalog `search()` like the FTS fallback does (`db.dart:672-684`).
- **Acceptance:** Test with 1000 seeded books: `allBooks` executes ≤4 queries (assert via statement counter or timing threshold). Gates green.

### T2.4 Batch writes; enable WAL
- **Target:** `lib/core/db.dart:51` (open), `:200-210` (`_write`), `lib/import/importer.dart:86-96`, `lib/fts/indexer.dart`
- **Current:** one BEGIN/COMMIT (≈fsync) per `addBook`/`updateBook`/`replaceBookFts` → 2 fsyncs per imported book, 1 per indexed book; no WAL.
- **Change:** At open: `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;`. Add `addBooks(List<Book>)` wrapping one transaction; batch `replaceBookFts` per `indexAll` run. Fix the O(B²) FTS state file churn: load state once, save once per run (`fts/indexer.dart:114-121`). Make `_write` re-entrant via a depth counter + savepoints (or require an explicit outer transaction).
- **Acceptance:** Import test of 200 books completes in one transaction (assert via timing/order-of-magnitude improvement or commit count). Gates green.

### T2.5 Index FTS from memory; stop extract-to-disk round trip
- **Target:** `lib/fts/indexer.dart:70-85,91-107`, `lib/formats/epub.dart:149-161`
- **Current:** indexer writes EVERY archive entry (images, fonts) to disk, reads chapters back, then deletes the tree — O(2× book size) wasted I/O per book; the decoded archive is already in memory. Also fix the MOBI temp-dir leak when `_imageDir` is empty (`mobi.dart:200-205`).
- **Change:** Build a `Map<String, ArchiveFile>` once in `EpubBook` (fixes the linear entry scans too); read chapter bytes directly from memory for FTS; skip extraction for indexing entirely.
- **Acceptance:** Indexing a test EPUB performs no temp-dir writes (assert via temp-dir watch or refactored API surface that makes extraction impossible on this path). Gates green.

### T2.6 Never query in `build()`; split the `AppState` god object
- **Target:** `lib/app_state.dart` (whole file), `lib/main.dart:216-230`, `lib/ui/library_page.dart:31,65-66,72`, `lib/ui/stats_page.dart:29-40,124-144`, `lib/ui/shelves_page.dart:179,300`
- **Current:** sqlite + FTS queries execute inside `build()` on every rebuild/keystroke; one `InheritedNotifier<AppState>` + `ListenableBuilder(MaterialApp)` rebuilds the entire app per notification; plugin events forward app-wide (`app_state.dart:36`); config saves are sync disk writes per keystroke (`core/config.dart:89-93`).
- **Change:** Move query execution behind async boundaries in `AppState`/controllers; cache FTS results per query string; replace the stats N+1 loop with one `GROUP BY` query. Split into focused notifiers (library view / appearance / reader prefs) with selector-style subscription; debounce config saves (idle flush); remove the blanket plugin→app listener and the redundant `AnimatedBuilder` in `library_page.dart:22-25`.
- **Acceptance:** Typing in the search box does not rebuild `MaterialApp` (assert via build counter in widget test); stats page issues O(1) queries. Gates green.

---

## PHASE 3 — P2 plugin system (root causes of two historical bug reports)

### T3.1 Unify store loader onto `_ArchiveFinder`
- **Target:** `sidecar/vellum_sidecar/vendor/store.py:28-103`, `sidecar/vellum_sidecar/vendor/loader.py:264-288`
- **Current:** store loader execs every top-level `.py` eagerly under a bare module name, no `calibre_plugins.*` namespace, `__init__.py` exec'd before siblings exist in `sys.modules`, subpackages ignored → real calibre store plugins with sibling imports fail to load. Hypothesized root cause of "vellum-flutter is not recognizing calibre plugins".
- **Change:** Route store zips through `loader.py`'s `_ArchiveFinder`/`_ArchiveLoader` (lazy, `calibre_plugins.`-namespaced, package-aware). Classify store-vs-metadata by CONTENT (subclass scan for `StorePlugin`/`StoreBase` vs `Source`), not by the `plugin-import-name-store_*.txt` marker.
- **Acceptance:** New sidecar test: fixture store zip whose `__init__.py` does `from . import search` and `from calibre_plugins.store_x.search import ...` loads and searches. Gates green.

### T3.2 Surface plugin failures to the UI
- **Target:** `sidecar/vellum_sidecar/bridge.py:103-106`, `lib/main.dart:77-84`, `lib/plugins/sidecar_client.dart:123,176`, `lib/ui/plugins_page.dart`
- **Current:** `load_all` swallows all per-zip failures (`log.warning`/`log.exception` then continue); sidecar start failure is `debugPrint` only; `stderrLog` grows unbounded and nothing reads it → broken plugins are invisible.
- **Change:** `load_all` returns `failures: [{zip, reason}]`; render per-zip errors on the Plugins page; surface "plugins unavailable (no python3)" state; ring-buffer `stderrLog` (e.g. 500 lines) and expose it in a diagnostics view.
- **Acceptance:** Installing a deliberately broken zip shows its name + reason on the Plugins page. Gates green.

### T3.3 Content-based download resolution with real errors
- **Target:** `sidecar/vellum_sidecar/vendor/store.py:147-192`, `lib/ui/store_page.dart:85-92`
- **Current:** resolution only works via a module-level function named exactly `resolve_spa_download(sr, timeout)`; all exceptions → `None`; UI shows generic "Could not resolve download link" toast. Hypothesized root cause of "libgen plugin can't resolve download link".
- **Change:** Probe multiple resolution strategies (module fn, plugin method, pre-populated `downloads` dict, `open()`); return `{"error": reason}` on failure and show the reason in the toast. Give `SearchResult` real attribute storage instead of `__getattr__ → ""` (`calibre_shim.py:782-784`). Implement `verify_ssl_certificates` via `ssl` contexts, gzip handling, and `format_date` in the shim (`calibre_shim.py:264,300-301,686-687`); where a feature is deliberately unsupported, raise loudly instead of returning plausible-wrong data.
- **Acceptance:** Sidecar test: a store plugin resolving via a plugin-class method (not the magic fn name) succeeds; a failing resolver returns its exception text to the UI. Gates green.

### T3.4 Threaded bridge dispatch with deadline semantics
- **Target:** `sidecar/main.py:24-40`, `sidecar/vellum_sidecar/bridge.py:167-180`, `lib/plugins/sidecar_client.dart:189-191,261-266`
- **Current:** synchronous stdin loop; one stalled plugin blocks ALL requests including `ping`; the same `timeout` is passed to each of N plugins sequentially (N×timeout server-side vs 1× client-side → guaranteed abandonment); abandoned requests keep running; late responses dropped.
- **Change:** Dispatch each request on a worker thread (guard the registry with a lock); pass a monotonic DEADLINE, not per-plugin timeout; honor the `abort` event already created at `loader.py:52-57` for cancellation.
- **Acceptance:** Sidecar test: a plugin sleeping 30s does not delay a concurrent `ping` beyond 1s. Gates green.

### T3.5 Protocol hygiene
- **Target:** `sidecar/main.py`, `sidecar/vellum_sidecar/vendor/calibre_shim.py:547-548,822-824`
- **Current:** shim `prints()` writes to stdout = the JSON protocol channel; `_open_url` launches a browser from the headless sidecar; no protocol version handshake; errors are unstructured `str(exc)`.
- **Change:** Route plugin `prints()` to stderr; make `_open_url` log-and-report-URL (never open); add a `hello` method returning `{protocol_version, python_version, deps: {requests, bs4, lxml: version-or-missing}}`; structured errors `{error: {type, message}}`. Also: rescan plugin dir when `loaded` is called and dir mtime changed (`bridge.py:38,116-118,163-165`); extend `unload` to store plugins.
- **Acceptance:** Sidecar test: a plugin calling `calibre.prints('hello')` mid-request does not corrupt responses; `hello` reports a missing dep correctly (monkeypatched import). Gates green.

---

## PHASE 4 — P3 release pipeline (root cause of "pushed but no update present")

### T4.1 Automate publish; fail closed on signing
- **Target:** `tool/build-flatpak.sh:14,30`, new `tool/publish-flatpak.sh`
- **Current:** build script exports only to local `build/flatpak-repo`; the copy to the gh-pages ostree repo is manual and undocumented; unsigned export is the DEFAULT while `io.github.vellum.Vellum.flatpakref:10` pins a GPG key (clients silently refuse unsigned commits). Live repo verified healthy today — failure mode is transient process error.
- **Change:** Add `tool/publish-flatpak.sh`: rsync `--delete` into a gh-pages checkout, commit, push. Make `build-flatpak.sh` ABORT when `FLATPAK_GPG_KEY` is unset unless `--unsigned` is explicitly passed. Document the full pipeline in README.
- **Acceptance:** Running the build without the key exits non-zero with a clear message. Shell scripts pass `shellcheck` if available.

### T4.2 Single-source versioning + release gate
- **Target:** `pubspec.yaml:17`, `data/io.github.vellum.Vellum.metainfo.xml:27`, git tags
- **Current:** version hand-edited in 3 places; nothing enforces agreement → software centers show "no update" when metainfo isn't bumped.
- **Change:** New `tool/release.sh`: reads version from `pubspec.yaml`, stamps a dated `<release type="stable">` into metainfo.xml, creates the git tag, then builds. CI check that all three agree.
- **Acceptance:** `appstreamcli validate data/io.github.vellum.Vellum.metainfo.xml` passes; release script dry-run prints consistent version across all three.

### T4.3 Minimal CI (none exists)
- **Target:** new `.github/workflows/ci.yml`
- **Change:** PR job: `flutter analyze`, `flutter test`, `python3 -m pytest sidecar/tests`, `appstreamcli validate`, `desktop-file-validate data/io.github.vellum.Vellum.desktop`. Tag job: full `tool/build-flatpak.sh` build + signed export + publish to gh-pages.
- **Acceptance:** Workflow file validates (`actionlint` or GH schema); a test PR run is green.

### T4.4 Runner one-liners
- **Target:** `linux/CMakeLists.txt:10`, `linux/runner/my_application.cc:183`
- **Current:** `APPLICATION_ID "io.github.vellum.vellum"` (lowercase) mismatches desktop/metainfo/manifest `io.github.vellum.Vellum` → broken Wayland dock icon/grouping. `G_APPLICATION_NON_UNIQUE` + always-TRUE `local_command_line` spawns a new process per invocation on a shared SQLite catalogue → lock contention.
- **Change:** Set `APPLICATION_ID "io.github.vellum.Vellum"`; drop `G_APPLICATION_NON_UNIQUE` (default single-instance; forward `activate` to primary).
- **Acceptance:** `grep` confirms both edits; launching twice focuses the existing window (manual smoke).

### T4.5 Get binaries out of git; tighten sandbox
- **Target:** `flatpak/io.github.vellum.Vellum.yml:24-25,32-46`, `flatpak/libpdfium.so`, `flatpak/wheels/`, `.gitignore`
- **Current:** 14 MB of committed binaries (7.7 MB pdfium, 12 wheels incl. 5.1 MB lxml, cp313-only); full clone took 300s+; wheels hard-couple to GNOME 49's Python 3.13; `--filesystem=home:ro` exposes all of $HOME (incl. ~/.ssh) to plugin code.
- **Change:** Replace wheels with manifest `type: file` sources (upstream PyPI URL + sha256, generated per-runtime via `flatpak-pip-generator`); fetch pdfium in `tool/build-flatpak.sh` from the pinned bblanchon release (`flatpak/PDFIUM-VERSION`) with sha256 check; drop `home:ro` (rely on document portal via `file_selector`; keep `xdg-documents`). Do NOT rewrite git history in this pass — note it as a follow-up decision for the owner.
- **Acceptance:** Manifest builds offline after fetch; `git ls-files` shows no `.so`/`.whl`; sandboxed app still opens a calibre library via the file picker.

---

## PHASE 5 — Quick wins (small, independent; batch into one branch)

| ID | Target | Change |
|----|--------|--------|
| Q1 | `lib/ui/store_page.dart:53-56` | Stop swallowing search errors: toast + error state page instead of fake "No results". |
| Q2 | `lib/main.dart:163-167` | Ctrl+F must not `popUntil(isFirst)` — scope the binding to the home route; never pop the reader. |
| Q3 | `lib/ui/reader_page.dart:944-945` | Restore Copy: return `AdaptiveTextSelectionToolbar` with Copy/Select All + existing Highlight/Define. |
| Q4 | `lib/ui/reader_page.dart:782-880` | Reader header: move font/theme/highlights into an overflow `PopupMenuButton`; fixes overflow < ~700 px. |
| Q5 | `lib/ui/shelves_page.dart:240,269-271,319` | `unawaited(...)` + `catchError` → toast on the fire-and-forget shelf futures. |
| Q6 | `lib/ui/library_page.dart:34-36` | Empty search result shows "No results for '<query>'" status instead of a blank page. |
| Q7 | `lib/ui/metadata_dialog.dart:296-300` | Replace hardcoded 620×580 dialog with the `ConstrainedBox`+MediaQuery pattern from `preferences_dialog.dart:99-103`; add `cacheWidth: 96` to result covers (`:573-578`). |
| Q8 | `lib/ui/stats_page.dart:270-279` | Don't render raw `end_locator` (`epub:3:0.5123`) to users; render "Section N" or drop the line. |
| Q9 | `lib/ui/book_details_page.dart:49-52,181` | Move `File.existsSync()` out of the build path; resolve once async and cache. |
| Q10 | `lib/core/models.dart:29-46` + `lib/ui/metadata_dialog.dart:241-274` | Make `Book` immutable (`copyWith` already exists); dialog edits a copy, persists, swaps on success — failed saves must not leave mutated shared state. |
| Q11 | `lib/ui/widgets/book_cover.dart:112-126,206-210` | Add `Semantics` labels (cards: "$title by $authors"; covers: "Cover of $title"). |
| Q12 | `lib/main.dart:88-101` + `lib/core/db.dart:183-196` | Replace ad-hoc schema probing with `PRAGMA user_version` + numbered migration list; move the demo-book purge into migration N (it can currently delete real user books titled e.g. "Dune"). |
| Q13 | `lib/core/db.dart:31-38` | Bundle sqlite3 with the Linux build instead of probing host `libsqlite3.so`; OR document the runtime dep. Choose bundling. |
| Q14 | `lib/store/store_download.dart:68-70` + `lib/ui/store_page.dart:113-116` | Downloads: max-bytes cap + total deadline (not just per-chunk liveness), temp-name + atomic rename, delete partials on error. |
| Q15 | `lib/metadata/engine.dart:69-77,271-275,307-340` | Precompute fuzzy scores once (Schwartzian), hoist regexes to static finals, hoist `_normalize(query)` out of the comparator. |

**Acceptance for Phase 5:** each item verified by its own targeted check or widget test; all gates green at the end.

---

## Explicitly out of scope (owner decisions needed — do NOT implement)

- Git history purge of committed binaries (`git filter-repo`) — rewrites published history.
- aarch64 support — requires CI/hardware decision.
- Replacing `pdfium_dart` (0.1.x) with `pdfrx` — the inventory doc names `pdfrx`; evaluate after Phase 1 stabilizes.
- Two-cover-location unification (`importer.dart:97-100` writes `<libraryDir>/covers/`, `metadata_dialog.dart:255-259` writes `<dataDir>/covers/`) — needs a data-migration decision; flag for owner.

## Definition of done (whole plan)

All phases' gates green; `flutter analyze` clean; `flutter test` + `pytest sidecar/tests` green; manual smoke: open app → import folder → search → read EPUB + PDF → switch library → install broken plugin (see error) → download from store plugin → no crash.log entries beyond clean startup markers.

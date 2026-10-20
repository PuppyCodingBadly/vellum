# Vellum DATA/FORMATS slice — implementation contract (from Python source)

Original source (authoritative, readable): /tmp/vellum/src/vellum/core/*.py and /tmp/vellum/tests/test_{db,covers,sorting,calibre,importer,store,epub,mobi,pdfbook,dictionary,gestures}.py

## models.py
Two dataclasses:
```python
@dataclass
class Author:
    name: str
    sort: str = ""

@dataclass
class Book:
    id: int | None = None
    title: str = ""
    authors: list[str] = field(default_factory=list)
    sort: str = ""
    isbn: str = ""
    publisher: str = ""
    pubdate: str = ""
    language: str = ""
    description: str = ""
    tags: list[str] = field(default_factory=list)
    formats: list[str] = field(default_factory=list)
    cover_path: str = ""
    path: str = ""
    rating: float = 0.0
    added: str = ""
    hidden: bool = False
    source_id: str = ""
```

## db.py — class Library
`Library(path)`; `:memory:` → one persistent reused connection; else new connection per call. Every connection: `PRAGMA foreign_keys = ON`. Commit-on-exit semantics.

Verbatim schema:
```sql
CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    sort TEXT NOT NULL DEFAULT '',
    isbn TEXT NOT NULL DEFAULT '',
    publisher TEXT NOT NULL DEFAULT '',
    pubdate TEXT NOT NULL DEFAULT '',
    language TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    cover_path TEXT NOT NULL DEFAULT '',
    path TEXT NOT NULL DEFAULT '',
    rating REAL NOT NULL DEFAULT 0.0,
    added TEXT NOT NULL DEFAULT '',
    hidden INTEGER NOT NULL DEFAULT 0,
    source_id TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS authors (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    sort TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS book_authors (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    author_id INTEGER NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (book_id, author_id)
);
CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS book_tags (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (book_id, tag_id)
);
CREATE TABLE IF NOT EXISTS formats (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    format TEXT NOT NULL DEFAULT '',
    path TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (book_id, format)
);
CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    position TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT 'yellow',
    text TEXT NOT NULL,
    created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS reading_positions (
    book_id INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    locator TEXT NOT NULL,
    updated TEXT NOT NULL
);
```
No indexes/triggers; only `foreign_keys = ON`.

Migrations (applied by open() if column missing per `PRAGMA table_info(books)`):
```sql
hidden:     ALTER TABLE books ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0
source_id:  ALTER TABLE books ADD COLUMN source_id TEXT NOT NULL DEFAULT ''
```

Public API:
- open()/close() (close only matters for :memory:)
- add_book(book) -> int — if added empty, set UTC ISO now; INSERT 13 cols; _write_links; sets+returns id.
- update_book(book) — KeyError("book has no id") if id None; KeyError(id) if rowcount 0; then _write_links.
- get_book(id) -> Book?
- all_books(include_hidden=false) — WHERE hidden=0 unless include; ORDER BY title.
- search(query, include_hidden=false) — empty/whitespace → all_books. AND over whitespace tokens; per-token OR:
```sql
(lower(b.title) LIKE ? OR lower(b.isbn) LIKE ?
 OR EXISTS (SELECT 1 FROM book_authors ba JOIN authors a ON a.id = ba.author_id
   WHERE ba.book_id = b.id AND lower(a.name) LIKE ?)
 OR EXISTS (SELECT 1 FROM book_tags bt JOIN tags t ON t.id = bt.tag_id
   WHERE bt.book_id = b.id AND lower(t.name) LIKE ?))
```
  Append `b.hidden = 0` unless include_hidden; ORDER BY b.title. 4 LIKE params per token, lowercased.
- delete_book(id) — cascades children.
- delete_books_without_files(titles: set) -> int — `DELETE FROM books WHERE path='' AND title IN (...) AND NOT EXISTS (SELECT 1 FROM formats f WHERE f.book_id=books.id)`; 0 for empty set; deletes hidden too.
- set_hidden(id, hidden) — KeyError on rowcount 0.
- find_by_source_id(source_id) -> Book? — None for falsy; `WHERE source_id=? ORDER BY id LIMIT 1`.
- add_highlight(book_id, position, color, text) -> int — created=UTC ISO now.
- list_highlights(book_id) -> list of maps {id, book_id, position, color, text, created} ORDER BY created, id.
- delete_highlight(id).
- set_reading_position(book_id, locator) — INSERT OR REPLACE with updated=UTC ISO now.
- get_reading_position(book_id) -> String?
- base_dir → cwd for :memory:, else parent of resolved db path.

Internals: get-or-insert author/tag by UNIQUE name. _write_links DELETEs then reinserts: authors with position=list index; tags; formats as (book_id, fmt, book.path) — every format row stores book's main path. Hydration: authors ORDER BY ba.position; tags ORDER BY t.name; formats ORDER BY format. hidden=bool(row[12]).

Test-asserted: round trip incl. author order, tag alpha sort; get_book(9999)=None; search AND tokens case-insensitive across title/author/tag/isbn; update replaces links; update unknown id → KeyError; cascade delete; :memory: works; hidden excluded by default; migration from schema without hidden/source_id must open and work.

## covers.py
Constants: THUMB_MAX_WIDTH=320, THUMB_MAX_HEIGHT=480, MAX_COVER_BYTES=25MiB, MAX_COVER_PIXELS=80_000_000.
- thumb_cache_path(data_dir, book_id, cover_path) → `<data_dir>/covers/thumbs/<book_id>-<sha1(realpath(cover_path))[:12]>.png`.
- thumb_path(data_dir, book_id, cover_path) → fallback to original cover_path on: missing/empty path, any exception, thumb fresh (mtime >= cover mtime → return thumb), size > MAX_COVER_BYTES, zero dims or w*h > MAX_COVER_PIXELS, decode failure. Else scale min(320/w, 480/h, 1.0), dims max(1, round(d*scale)), PNG.
Tests: 1200×1800 → exactly 320×480; distinct digests per cover path; mtime regen rule; garbage/missing → input path.

## sorting.py
SORT_OPTIONS = (("title","Title"),("author","Author"),("rating","Rating"),("added","Recently added")); SORT_KEYS = keys.
sort_books(books, key="title"): title key = (title or "Untitled").casefold(); author key = (", ".join(authors) or "\uffff").casefold().
- author: (author_key, title_key) asc
- rating: (-rating, title_key)
- added: dated books sorted (added, title_key) REVERSED, then undated sorted by title asc
- default/unknown → title asc. New list, stable.

## gestures.py
SWIPE_MIN_VELOCITY=250.0, SWIPE_DIRECTION_RATIO=1.5.
swipe_direction(vx, vy, min=250): |vx|<min → 0; |vx| < |vy|*1.5 → 0; else -1 if vx<0 (left/next), 1 if right/prev.
Tests: (-800,20)→-1, (800,-20)→1, (800,900)→0, (-100,0)→0, (0,800)→0.

## epub.py — class EpubBook(path)
ValueError on: bad zip/OSError; missing META-INF/container.xml; container parse error; no rootfile full-path; unreadable/unparseable OPF.
Parse: first <rootfile> (localname match) full-path, URL-unquoted; opf_dir=dirname. Walk OPF by localname: item → manifest[id]=(href, media-type), if "nav" in properties.split() → nav_href; itemref → idrefs; spine toc attr → ncx via manifest. NCX fallback: first manifest item with media-type application/x-dtbncx+xml. Spine: idrefs whose manifest media-type is application/xhtml+xml or text/html, or href ends .xhtml/.html/.htm; hrefs URL-unquoted.
Titles: NCX preferred — navPoint/navTarget: first <text> label + first <content src>; nav doc only if NCX yielded nothing — every <a href> with itertext. Href keys normalized: unquote, strip #fragment. Missing title → stem: basename no ext, `_`→space, `-`→space.
API:
- chapters() -> list of (href relative to opf_dir, title)
- extract_to(dest_dir) -> abs path of OPF dir; idempotent via `.extracted` marker ("ok"); extractall first call.
- chapter_file(dest_dir, index) -> abs path joining opf dir + href split on `/`.
Tests: spine order respected (c2,c1,c3) with NCX titles; stem fallback; extract idempotent; encoded href chapter%201.xhtml resolves; garbage/missing-container → ValueError.

## mobi.py — class MobiBook(path)
Constants: PDB_HEADER_LEN=78, MOBI_HEADER_OFF=16, FIRST_NON_BOOK_OFF=0x50, FIRST_IMAGE_OFF=0x6C, MIN_MOBI_HEADER=0x70.
Validation: len ≥ 86 and data[60:68]==b"BOOKMOBI"; num_records >H at 76; record table 8B/record with >I offsets; bounds-checked. Record 0: len ≥ 16+0x70; compression >H at 0 ∈ {1, 2(PalmDOC LZ77)}; text_length >I at 4; text_record_count >H at 8; MOBI magic at offset 16; encoding >I at +0x0C; first_non_book at +0x50; first_image at +0x6C (clamped to num_records).
Text: decompress records[1:1+count] if compression==2 via palmdoc LZ77 (0→literal 0; 1–8→copy next c bytes; ≤0x7F literal; 0x80–0xBF: 2-byte pair, distance=pair>>3, length=(pair&7)+3, break if distance>len(out); ≥0xC0: space + (c^0x80)), concat, truncate to text_length, decode utf-8 if encoding ∈ (0,65001) else cp<encoding>, fallback utf-8.
Sections (_split_sections): split at `<mbp:pagebreak\s*/?>` ends if any, else at lookahead positions before <h1|h2 (excluding pos 0); drop chunks with no text after tag-strip; title = text of first <h1>/<h2> (tags stripped) else "Section N".
API:
- sections() -> list of (record_offset:int, title)
- section_html(index) — IndexError out of range; lazy-extracts images to temp dir if needed; rewrites `<img recindex="N">` → record first_image + N - 1 (1-based), adds src="file://…" if extracted, strips recindex, emits `<img src="..." attrs />`; wraps in DOCTYPE html + meta charset + body.
- extract_to(dest_dir) — idempotent via `.extracted` marker ("ok\n"); writes records from first_image whose bytes match magic (JPEG ff d8 ff → .jpg, GIF87a/89a → .gif, PNG → .png) as img-<recindex><ext>; on re-entry rebuilds map from dir listing.
Tests: titles Alpha/Beta ascending offsets; img rewrite to img-3.gif well-formed; cp1252 "Café"; extract idempotency; garbage → ValueError.

## pdfbook.py — class PdfBook(path)
Poppler GI + cairo. DEFAULT_SCALE=1.75.
- init: document from file; ValueError on failure or page count < 1.
- page_count() -> int
- render_page(index, scale=1.75) -> PNG bytes — IndexError out of range; surface max(1,int(w*scale)) × max(1,int(h*scale)).
- title_at(index) -> page label or "Page {index+1}".
(Dart port: use pdfrx instead of Poppler; same API shape.)

## dictionary.py
API_URL="https://api.dictionaryapi.dev/api/v2/entries/{language}/{word}", WIKTIONARY_URL="https://{language}.wiktionary.org/api/rest_v1/page/definition/{word}", UA="Vellum/0.1 (ebook reader; contact: none)", MAX_MEANINGS=3, MAX_DEFINITIONS=3.
lookup(word, language="en") -> map or null: strip+lowercase; empty → null without request. dictionaryapi first: GET timeout=8, URL-quoted word (safe=""); 404 → fall to Wiktionary; data[0]; phonetic = top-level phonetic else first non-empty phonetics[].text; meanings first 3, each {partOfSpeech, definitions: first 3 non-empty stripped}. Any error → Wiktionary: GET timeout=8 UA header; 404 → None; response {lang:[entries]}; ≤3 meanings total; definitions HTML-stripped (re.sub <[^>]+> then unescape, strip), first 3; skip empty; none → fail → None. lookup never raises.
Tests: timeout=8; URL .../es/hola; phonetic first-non-empty; caps; HTML unescape; primary network error falls back.

## importer.py
SUPPORTED={".epub",".mobi",".pdf"}.
import_path(library, path) -> list[int] — dir → sorted(rglob("*")) supported files; single supported file; else []. Per file _import_file, exceptions skipped.
_import_file: base Book(title=file.stem, formats=[ext], path=file). EPUB additionally reads OPF metadata + cover; keep stem title if empty; on exception base book, no cover. add_book; if cover: write <base_dir>/covers/<book_id>.<ext>, set cover_path, update_book.
_read_epub (import-time metadata only): locate OPF via container.xml rootfile (only if full-path literally in namelist), else first .opf (sorted, case-insens endswith), else ValueError. opf_dir = parent ("" for "."). Metadata: only DC-namespaced elements: first non-empty title; each creator appended; identifier taken as ISBN if "isbn" in text (case-insens) or any attr value (stripped,lowered)=="isbn" — strips urn:isbn:/isbn: prefixes (case-insens); first language, publisher, date→pubdate, description.
_find_cover precedence: (1) EPUB3 manifest item with cover-image in properties.split(); (2) EPUB2 <meta name="cover" content="id">; (3) any manifest image whose id or href contains "cover" (lower). Resolve: unquote(href), normpath(join(opf_dir, href)), `\`→`/`; retry raw href if absent; ext = href suffix lower else "jpg".
Tests: percent-encoded cover href found; opf:scheme="ISBN" identifier → isbn.

## calibre.py
_PREFERRED_FORMATS=("epub","pdf","mobi","azw3"). _SKIP_TAGS={"script","style"}.
CalibreImportResult{added=0, skipped=0, failed=0, first_error=""}.
is_calibre_library(folder) → metadata.db is_file.
import_calibre_library(library, folder, progress) — resolves; missing metadata.db → ValueError. Opens via snapshot; verifies books table exists else ValueError("not a calibre metadata database"). Streaming cursor SELECT <available of id,title,sort,isbn,pubdate,path,uuid,has_cover> FROM books ORDER BY id + COUNT(*). Per row: _import_row → added; returns False → skipped; exception → failed++, first_error=f"{type}: {exc}" (first only); continue. progress(done,total) at done%25==0 or done==total.
Snapshot: TemporaryDirectory(prefix="vellum-calibre-", dir=<base_dir>/tmp/calibre if creatable); copy2 metadata.db + -wal/-shm sidecars; read-only (PRAGMA query_only=ON). NEVER modifies source.
Per-book queries (all optional, guarded by table existence, catching errors):
- authors: SELECT a.name FROM authors a JOIN books_authors_link l ON l.author=a.id WHERE l.book=? ORDER BY l.id
- tags: SELECT t.name FROM tags t JOIN books_tags_link l ON l.tag=t.id WHERE l.book=? ORDER BY t.name
- publisher: publishers/books_publishers_link ORDER BY l.id first
- language: languages/books_languages_link (bll.lang_code=l.id) ORDER BY bll.id first
- description: SELECT text FROM comments WHERE book=? first → html_to_text
- rating: ratings/books_ratings_link → clamp(0..5, rating/2.0); ValueError→0.0
- isbn: SELECT value FROM identifiers WHERE book=? AND lower(type)='isbn' ORDER BY id first stripped; else books.isbn
_format_files: needs data table {book,format,name}; case-insens match <name>.<format-lower> in book dir listing; returns {fmt_lower: abs_path}.
_cover_file: only if has_cover; tries cover.jpg, cover.jpeg, cover.png.
_join_inside(root, *parts): abspath; "" if commonpath != root (test: '../escape' → path "" and formats []).
_pubdate: first 4-digit year via re.match(r"(\d{4})") else whole string.
_import_row: source_id=f"calibre:{uuid}" or f"calibre:{root}:{book_id}"; skip if find_by_source_id (even hidden). title stripped or "Untitled"; path = first preferred format present else any file else ""; formats=sorted(files); add_book.
_html_to_text: HTMLParser convert_charrefs; script/style skipped via depth counter; block tags append "\n" start+end; <td> appends " "; final: split lines, collapse whitespace, strip, drop empties, join "\n". Test: "<p>One</p><p>Two &amp; three</p>" → "One\nTwo & three".
Tests: full fixture import (rating 4.5, source_id calibre:uuid-1, formats ["epub","pdf"], epub preferred); reimport skipped; hidden reimport skipped stays hidden; missing db ValueError; read-only WAL imports 2; per-row failure recorded not fatal; broken link table → tags [] but added; snapshot dir == <base_dir>/tmp/calibre.

## store.py
StoreResult{title, author, formats, detail_item, cover_url, download_url, store_name} all str.
is_store_plugin(zip): contains entry whose basename matches plugin-import-name-store_*.txt; False on bad zip.
load_store_plugin(zip) -> StoreAdapter? — None unless store plugin; calibre_shim.install(); import name from marker content (or filename-derived); loads top-level .py under <import_name>/ (or zip root), __init__.py first, exec'd into synthetic package in sys.modules; scans for class subclassing calibre.customize.Plugin (not Plugin itself, __module__==pkg) for name/description; default name=zip stem.
StoreAdapter(name, description, zip_path, modules):
- _find_search_fn: first module attr search_libgen, else first callable starting with "search" (not a class).
- search(query, max_results=10, timeout=60) — exceptions → []; maps attrs title/author/formats/detail_item/cover_url via str(getattr(...,"") or ""); store_name=self.name.
- fetch_download(result, timeout=60) -> StoreResult? — needs module with callable resolve_spa_download; builds shim SearchResult, copies fields, calls resolve_spa_download(sr, timeout); falsy → None. Chooses from sr.downloads dict: first format in result's comma-separated formats matching a downloads key case-insensitively (sets result.formats to that); fallback first non-empty entry; updates cover_url if present; sets download_url. Exceptions → None.
Tests: fake zip (marker + __init__.py StoreBase "Fake Store" + fake_plugin.py with search_libgen, resolve_spa_download); search returns 2 results; fetch_download picks EPUB from {"MOBI":…,"EPUB":…} given formats "EPUB, MOBI"; metadata zip rejected; PluginManager skips store zips.

## Architecture
models ← everything. db.Library is catalogue; importer and calibre write via add_book/find_by_source_id; covers at <library.base_dir>/covers/<id>.<ext>, thumbs at <data_dir>/covers/thumbs/<id>-<sha1[:12]>.png. EpubBook/MobiBook/PdfBook are reader-side parsers. store adapts calibre store-plugin zips through plugins/calibre_shim. sorting/gestures pure.

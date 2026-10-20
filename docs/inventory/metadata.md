# Vellum METADATA + PLUGINS slice — implementation contract (from Python source)

Original source (authoritative, readable): /tmp/vellum/src/vellum/metadata/** and /tmp/vellum/src/vellum/plugins/**, tests /tmp/vellum/tests/test_{metadata,extra_sources,universal,shim}.py

## 1. Data model (sources/base.py)
```python
@dataclass
class Metadata:
    title: str = ""
    authors: list[str] = []
    isbn: str = ""
    publisher: str = ""
    pubdate: str = ""
    language: str = ""
    description: str = ""
    tags: list[str] = []
    rating: float = 0.0      # 0.0–5.0
    cover_url: str = ""
    source_id: str = ""      # e.g. "gb-1", "/works/OL1W", "internet-archive:dune", "loc:<id>", "inventaire:Q…", "merged"
    source_name: str = ""
```
MetadataSource interface: class attrs id, name; search(title="", authors=None, isbn="", timeout=15.0) -> list[Metadata]; search_free_text(query, timeout) default delegates to search(title=query); download_cover(meta, timeout=15.0) -> bytes?.

### Merge semantics (MetadataEngine.merge_results, static)
- [] → None; 1 result → as-is.
- best = max by completeness key (count of truthy [title, authors, isbn, publisher, pubdate, language, description, cover_url], rating, len(description)).
- Copy of best; source_id="merged", source_name="Merged sources".
- title/isbn/publisher/pubdate/language: fill from first result with truthy value (list order) if merged's empty.
- description = longest non-empty. cover_url = first non-empty if merged lacks. authors/tags = concatenated order-preserving dedup across all. rating = max.

No source priority ordering: queried in registration order; dedupe keeps higher-rated duplicate; merged row prepended in find_all/find_query when ≥2 results.

## 2. Engine (metadata/engine.py)
register_source, sources().
### find(title, authors, isbn, timeout=15.0)
Sequential fan-out; per-source try/except swallowed. Collect → dedupe → filter English → return.
### _dedupe
Key: ("isbn", isbn) if isbn non-empty else ("ta", title.lower(), tuple(a.lower() for a in authors)). First occurrence kept; later dup with strictly greater rating replaces. Final sorted by -rating.
### _is_english
Empty language → kept. Else kept iff language.lower().startswith("en") or in ("english","eng"). "fre" dropped.
### find_query(query, timeout=15.0) — fuzzy free text
1. Whitespace-collapse; empty → [].
2. _query_isbn: strip to [0-9Xx]; 13 all-digit → ISBN-13; 10 chars first 9 digits + last digit/X → uppercased ISBN-10; else "".
3. ISBN path → find(isbn=…); no fuzzy sort, merged row still prepended if >1.
4. Text path: per source search_free_text(query, timeout) if exists else search(title=query). Dedupe + English filter. sort by (-_fuzzy_score(query, meta), -rating).
5. merged prepended if len(results)>1.
### _fuzzy_score
_normalize: lowercase → replace [^a-z0-9]+ with space → collapse → strip. Applied to query, title, ", ".join(authors).
- query empty → 0.0
- exact equality → 150.0
- query substring of title → 100.0
- else if title non-empty: SequenceMatcher(query,title).ratio()*40.0, +40.0 if title ⊂ query
- per query token: +12.0 if in title token set; +8.0 if in author token set, elif +4.0 if substring of authors string
- + max(0,rating)*2.0
- +100.0 if meta.isbn lowercased in normalized query
### find_all(...) = find + merged row when >1 (no config flag).
### fetch_cover(meta) -> bytes?
Match registered source where source.id==meta.source_id OR source.name==meta.source_name; call its download_cover(meta); exception → None, return immediately. No match: no cover_url → None; else GET cover_url (timeout 15, UA "Vellum/0.1 metadata grabber", stream); non-image/* Content-Type → None; 64KiB chunks, abort >10MiB → None.
### grab_url(url, timeout=20.0) = UniversalGrabber().grab(url, timeout).

## 3. Built-in sources — exact endpoints
Common: all request exceptions → log → []/None. limit/rows/maxResults = 20.

### GoogleBooks — id "google-books", name "Google Books"
GET https://www.googleapis.com/books/v1/volumes
- search: q = "intitle:{title}" + "inauthor:{a}" per author + "isbn:{isbn}", joined "+"; params {q, maxResults:20, langRestrict:"en"}. No parts → [].
- search_free_text: q = raw query, same other params.
- Parse items[].volumeInfo: ISBN first ISBN_13 else first ISBN_10; cover = imageLinks.thumbnail with "zoom=1"→"zoom=0"; rating=float(averageRating or 0); tags=categories; source_id=item["id"].
- download_cover: plain GET cover_url → content.

### OpenLibrary — id "openlibrary"
GET https://openlibrary.org/search.json
- Base params: limit=20, language="eng", fields="key,title,author_name,first_publish_year,publisher,language,subject,cover_i,isbn". search adds title, author=authors[0], isbn as present; all empty → []. free_text uses q=query.
- Parse docs[] (skip titleless): ISBN first 13-char else first; publisher/language first list element; pubdate=str(first_publish_year) or ""; tags=subject[:8]; rating=0.0; description=""; cover=https://covers.openlibrary.org/b/id/{cover_i}-L.jpg; source_id=key.
- download_cover: plain GET.

### InternetArchive — id "internet-archive"
GET https://archive.org/advancedsearch.php
- Query: isbn:({isbn}), title:({title}), creator:({first author}) joined " AND ", always suffixed " AND mediatype:texts AND language:(eng OR English)". Free-text: "({query}) AND mediatype:texts AND language:(eng OR English)".
- Params: {q, "fl[]":[identifier,title,creator,date,publisher,language,description,subject,isbn], rows:20, output:"json"}.
- Parse response.docs[] (skip no identifier/title): authors=deduped creator list; description HTML-stripped + unescaped + whitespace-collapsed; tags=subject[:8]; ISBN = first value whose digit/X strip yields 13 digits, else 10-char uppercased, else first raw; cover=https://archive.org/services/img/{quote(identifier)}; source_id="internet-archive:{identifier}".
- download_cover: streamed, image/* check, 10MiB cap.

### LibraryOfCongress — id "library-of-congress"
GET https://www.loc.gov/books/ params {q, fo:"json", c:20, fa:"language:english"}. q = isbn, else "{title} {first author}" trimmed; free-text = query.
- Parse results[] (skip titleless): authors=contributor list; publisher=item.created_published else top-level publisher (list-or-scalar, first); language likewise; isbn=number_isbn or isbn; description HTML-cleaned; tags=subject[:8]; cover=first of image_url (top-level else item.image_url) with #fragment stripped; source_id="loc:{id}".
- download_cover: streamed, NO Content-Type check, 10MiB cap.

### Inventaire — id "inventaire" (two-step)
1. GET https://inventaire.io/api/search params {search: query, types: "editions"|"works", limit:20}. ISBN present → editions search with ISBN; else works search of "title firstauthor" (or free-text).
2. results[] with uri; batch-fetch entities: GET https://inventaire.io/api/entities params {action:"by-uris", uris:"|".join(chunk)}, chunks of 40. Then fetch related URIs from claims wdt:P50 (author), wdt:P123 (publisher), wdt:P136 (genre), wdt:P407 (language), wdt:P629 (edition→work), minus already-fetched.
- Parse per result: entity by uri; work = first fetched P629 target. Title = English label of entity or work — NO English label → result dropped (source-level English restriction). Authors/publishers/languages from entity claims falling back to work claims (genres: work first then entity); resolved via English labels. ISBN = first P212 (entity→work), cleaned to 10/13 digits or "". pubdate = first P577 (entity→work). description = English description entity→work, whitespace-collapsed. Image = result.image or entity.image or work.image; absolute http(s) kept, leading "/" prefixed https://inventaire.io, else https://inventaire.io/img/entities/{value}. tags ≤8. source_id="inventaire:{entity uri tail}".
- download_cover: streamed, image/* check, 10MiB cap.

## 4. Universal URL grabber (metadata/universal.py)
UniversalGrabber(MetadataSource), id "universal-url", name "Web page"; search() always [].
### grab(url, timeout=20.0)
1. normalize_url: strip; empty or any whitespace char → ""; prepend https:// if no ^https?:// (case-insens); urlsplit (error → ""); scheme http/https, netloc non-empty no whitespace; host must contain "." unless localhost; "://" in url. Invalid → "".
2. grab raises ValueError("enter a valid http(s) URL") on empty normalized.
3. _fetch_html: streamed GET (UA "Vellum/0.1 (+https://github.com/PuppyCodingBadly/vellum) metadata grabber"); Content-Type present lacking html/xml → ValueError; read ≤4MiB in 64KiB chunks (truncate not fail); decode resp.encoding or utf-8, errors=replace. Returns (html, final_url).
4. parse_book_page(html, final_url); source_id=f"universal:{final_url}"; source_name defaults netloc.
### parse_book_page — extraction order, merge-with-missing (first non-empty wins per field)
1. JSON-LD: every <script type="application/ld+json">; json.loads(html.unescape(raw)), skip failures; flatten lists and @graph. Keep objects whose @type/type (list ok), last /-segment lowercased, ∈ {book, audiobook, product, creativework}.
   Fields: title=name|headline; authors=author name(s) (str/dict→name|@value|value/list-first; dedup); isbn=direct isbn, or identifier (dict: value/identifier if propertyID|name|@type empty or contains "isbn"; scalar taken), else gtin13|gtin|sku; publisher; pubdate=datePublished|dateCreated|releaseDate; language=inLanguage; description (HTML-stripped); cover=image|thumbnailUrl first URL (dict→url|contentUrl), absolutized; rating=aggregateRating.ratingValue * 5 / (bestRating or 5), clamped 0–5 rounded 0.1; tags=genre|keywords split on ,; deduped ≤12.
2. Meta/OpenGraph: both property= and name= attrs. Title og:title|twitter:title; authors book:author|og:book:author|author (each occurrence = one author, NOT comma-split); isbn book:isbn|og:book:isbn|isbn; publisher book:publisher|og:book:publisher|publisher; pubdate book:release_date|og:book:release_date|article:published_time|date; language og:locale|language; description og:description|twitter:description|description; cover og:image:secure_url|og:image|twitter:image|image (absolutized); tags book:tag|article:tag|keywords (comma/semicolon-split ≤12); site_name og:site_name → source_name.
3. Microdata: first [itemtype*="Book"|"Product"|"CreativeWork"] scope (else whole doc); [itemprop=…] value = content attr else href else src else text. Props: name→title, author (single), isbn, publisher, datePublished, description, inLanguage, image (absolutized).
4. Title fallback: <title> text; still empty → None.
URL absolutization: //x → https://x; absolute kept; else urljoin(base, value); no base → "". _clean: strips embedded HTML when both </> present; collapses whitespace.
download_cover: GET cover_url (http(s) only), image/* check, 10MiB cap.

## 5. Result sorting (metadata/sorting.py)
RESULT_SORT_OPTIONS = (("relevance","Relevance"),("title","Title"),("author","Author"),("rating","Rating"),("pubdate","Newest")); RESULT_SORT_KEYS = keys.
sort_metadata(results, key="relevance"):
- relevance/empty → input order copy.
- else partition: source_id=="merged" stay first; sort rest:
  - title: casefold(title or "Untitled")
  - author: (casefold(", ".join(authors) or "\uffff"), title-key)
  - rating: (-rating, title-key)
  - pubdate: dated first sorted by string pubdate DESCENDING, then undated by title.

## 6. Plugin system (plugins/) — Python sidecar in the port
### loader.py — load_plugin_zip(zip_path) -> MetadataSource
1. calibre_shim.install() first.
2. Import name: any zip member whose basename matches plugin-import-name-*.txt; content if non-empty else name-derived. Missing → ValueError.
3. Read {import_name}/__init__.py (fallback root __init__.py); contains "InterfaceActionBase" → ValueError("this is a Calibre GUI action plugin…").
4. _load_package: top-level .py under {import_name}/ (no deeper); fallback root .py. Package module __path__=[], in sys.modules; exec __init__.py first then sorted others as {import_name}.{stem}.
5. _find_plugin_instance: classes subclassing shim Source (not Source itself), __module__ starts with package name. First: try cls.load_actual_plugin(pkg), on exception cls(). None → ValueError.
6. Wrap in CalibrePluginAdapter.
### CalibrePluginAdapter
id = plugin.id or plugin.name or "calibre-plugin"; name/version/description stringified.
- search(title, authors, isbn, timeout): callable search → search(title=,authors=,isbn=,timeout=), translate each. elif callable identify → Queue+Event, identify(log, queue, abort, title=title or None, authors=authors, identifiers={"isbn":isbn} if isbn else {}, timeout=timeout); drain queue.
- download_cover(meta): fetch_cover or download_cover attr callable → calibre signature (log, queue, abort, title=…, authors=…, identifiers=…, timeout=…); on TypeError retry as fetch(meta); queue result bytes as-is; tuple → last element if bytes. Fallback urlopen(meta.cover_url, timeout).
- _translate: vellum Metadata → fill missing source_id/name. Else map calibre object: title, authors, identifiers["isbn"] or .isbn, publisher, str(pubdate), languages[0]→language, comments→description, tags, float(rating or 0.0), cached_cover_url (callable → call with False) → cover_url; source_id/name = adapter's.
### manager.py — PluginManager(engine, plugin_dir)
load_all(): sorted *.zip; store-plugin zips skipped (marker plugin-import-name-store_*.txt); failures isolated.
load(zip): ValueError if store plugin; copy into plugin_dir (unless same); load; engine.register_source; return adapter.name.
unload(name): pop; remove from engine._sources; delete zip.
loaded() → [{name, version, description}].
### calibre_shim.py — install() idempotent (checks calibre.__vellum_shim__)
Shimmed sys.modules: calibre (prints=print, browser() urllib opener UA "Vellum/1.0", ispy3=True, iswindows=False, islinux=True, isosx=False, url_slash_cleaner); calibre.customize (Plugin, StoreBase); calibre.customize.builtins (empty); calibre.ebooks.metadata (check_isbn, book, sources, MetaInformation/MetaData/Metadata=_Metadata); calibre.ebooks.metadata.book(.base) _Metadata (attrs title, authors, identifiers{}, tags[], rating/publisher/pubdate/comments/isbn=None, languages[]; set_identifier; is_null); calibre.ebooks.metadata.sources(.base) Source (subclass of shim Plugin; id/name/version/author/description; capabilities=frozenset(); touched_fields=frozenset(); no-op identify(log,rq,abort,title=None,authors=None,identifiers=None,timeout=30) and download_cover(…,get_best_cover=False)); calibre.customize.Plugin (name/author/version(0,0,0)/minimum_calibre_version/description; load_actual_plugin(pkg) classmethod — first Plugin subclass defined in package's own modules then imported, skipping shim classes); calibre.utils(.localization) canonicalize_lang=identity; .cleantitle clean_title=identity; .config JSONConfig=dict.
check_isbn: strip spaces/hyphens; ISBN-10 weighted sum %11==0 → normalized (X upper); ISBN-13 alternating 1/3 %10==0; else None.
Store shims: PyQt5 + PyQt5.Qt module __getattr__ → _Dummy (permissive ctor/callable/falsy/empty iter); calibre.gui2 (open_url=webbrowser.open, __getattr__ → _Dummy); calibre.gui2.store (StorePlugin — Plugin subclass, permissive __getattr__); calibre.gui2.store.basic_config (BasicStoreConfig options={}, get(k,default), permissive; BasicStoreConfigWidget=_Dummy); calibre.gui2.store.search_result (SearchResult DRM_UNLOCKED/UNKNOWN/LOCKED=0/1/2, attrs title/author/price/detail_item/cover_url/formats="", drm=DRM_UNKNOWN, downloads={}, unknown attrs read as ""); calibre.gui2.store.web_store_dialog (WebStoreDialog=_Dummy); calibre.customize.StoreBase.

## 7. Test-asserted behaviors (must preserve)
- GB: ISBN_13 preferred; zoom=1→zoom=0; q contains intitle:/inauthor:; maxResults=20; tags from categories; rating passthrough.
- OL: 13-digit ISBN preferred; pubdate "2020"; tags=subject[:8]; cover -L.jpg; source_id=key.
- Engine: dedupe by ISBN keeps higher rating, sorted rating desc; case-insens title+authors dedupe without ISBN; failing source swallowed; fetch_cover matches by id OR name, called once, no match → None.
- find_query("978-0-44-101359-3") → search(isbn="9780441013593").
- Fuzzy ranking: "dune frank herbert" → Dune(4.0) > Dune Messiah(5.0) > Cooking(5.0), merged first.
- find_query("   ") → []. language "fre" dropped, "en" kept.
- IA: HTML-stripped description; 13-digit ISBN; cover ends /dune; q contains title:(Dune); free-text q exactly "(dune herbert) AND mediatype:texts AND language:(eng OR English)".
- LOC: publisher from item.created_published; cover fragment stripped; source_id loc:.
- Inventaire: first request types="works"; label resolution from fetched entities; language fallback "English"; /img/entities/hash → absolute; source_id inventaire:Q…; work without English label dropped.
- Universal: JSON-LD relative image resolved; rating 9/10 → 4.5; description stripped; genre→tags. OG beats <title>; repeated book:author → two authors; og:site_name → source_name. Microdata scope beats <title>. No title → None. normalize_url adds https; rejects "Dune Frank Herbert", "dune", whitespace, "". grab raises ValueError.
- Shim: fixture zip fakesrc; adapter id fakesrc name "Fake Source"; search 2 translated results; manager.load copies zip, registers, returns name; loaded() → version "(1, 0, 0)" stringified; unload removes + deletes; load_all isolates corrupt zip.

## 8. Dart port notes
- One Metadata model, MetadataSource abstract class, MetadataEngine with same algorithms (SequenceMatcher.ratio → hand-rolled or string_similarity).
- Inventaire is the only two-phase source.
- Universal grabber: package:html parser.
- Plugin system maps to Python sidecar: loader/shim/manager semantics identical in sidecar, exposed over JSON-RPC stdio bridge.

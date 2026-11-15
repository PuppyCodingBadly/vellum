import 'dart:io';
import 'dart:isolate';

import '../core/db.dart';
import '../core/models.dart';
import '../formats/epub.dart';
import '../formats/mobi.dart';
import '../formats/text_extract.dart';

/// One book's extraction job.
///
/// Plain data only, so it and its result can cross the worker-isolate
/// boundary; the [Book] itself carries a live [Library] reference and must
/// stay on the main isolate.
typedef _ExtractJob = ({int bookId, String path, List<String> formats});

/// Extracts rows for [jobs] on a worker isolate so parsing never blocks the
/// UI, returning one entry per job in the same order (null = parse failure).
///
/// This top-level function owns the only isolate boundary in the indexer.
/// [jobs] holds plain data, and the entry closure below is created outside any
/// class, so it cannot capture `this`, the [Library] or an sqlite handle.
Future<List<List<Map<String, Object>>?>> _extractRows(List<_ExtractJob> jobs) =>
    Isolate.run(() => [for (final job in jobs) _extractBookRows(job)]);

/// Reads one book's chapter text. Runs on the worker isolate.
List<Map<String, Object>>? _extractBookRows(_ExtractJob job) {
  final rows = <Map<String, Object>>[];
  try {
    if (job.formats.contains('epub')) {
      final epub = EpubBook(job.path);
      final chapters = epub.chapters();
      for (var i = 0; i < chapters.length; i++) {
        rows.add({
          'chapter': i,
          'title': chapters[i].$2,
          'content': htmlToText(epub.chapterSource(i)),
        });
      }
    } else if (job.formats.contains('mobi')) {
      final mobi = MobiBook(job.path);
      final sections = mobi.sections();
      for (var i = 0; i < sections.length; i++) {
        rows.add({
          'chapter': i,
          'title': sections[i].$2,
          'content': htmlToText(mobi.sectionSource(i)),
        });
      }
    }
  } catch (e) {
    stderr.writeln('FtsIndexer: failed to index book ${job.bookId}: $e');
    return null;
  }
  return rows;
}

/// Full-text indexer for book content.
///
/// Extracts chapter text from EPUB and MOBI books (PDFs are image-rendered
/// and skipped) and stores rows via [Library.replaceBookFts]. The indexed
/// file signature is stored in the `fts_index_state` table beside those rows,
/// so a deleted book cannot leave behind a skip mark that would hide a later
/// re-import from search.
class FtsIndexer {
  FtsIndexer(this._library);

  final Library _library;

  /// Books committed per transaction. Extraction runs in a worker isolate;
  /// each batch is committed on the calling isolate, which then yields so the
  /// UI keeps painting during a long [indexAll].
  static const int _batchSize = 8;

  /// Builds the plain-data extraction job for [book].
  static _ExtractJob _jobFor(Book book) => (
    bookId: book.id ?? 0,
    path: book.path,
    formats: [for (final format in book.formats) format.toLowerCase()],
  );

  /// Indexes a single book, replacing any previous FTS rows for it.
  ///
  /// Parse failures are logged and the book is skipped. Returns true when
  /// the book was (re-)indexed, false when it was skipped.
  Future<bool> indexBook(int bookId) async {
    final book = _library.getBook(bookId);
    if (book == null) return false;
    final extracted = await _extractRows([_jobFor(book)]);
    final rows = extracted.single;
    if (rows == null) return false;
    _library.replaceBookFts(bookId, rows, source: FtsSource.of(book.path));
    return true;
  }

  /// Indexes every book in the library. Books whose source file is unchanged
  /// since the last index are skipped unless [force] is true. Returns the
  /// number of books (re-)indexed.
  Future<int> indexAll({bool force = false}) async {
    var indexed = 0;
    final pending = <({_ExtractJob job, FtsSource? source})>[];

    Future<void> flush() async {
      if (pending.isEmpty) return;
      final extracted = await _extractRows([
        for (final entry in pending) entry.job,
      ]);
      final entries = <int, FtsIndexEntry>{};
      for (var i = 0; i < pending.length; i++) {
        final rows = extracted[i];
        if (rows == null) continue; // parse failure: keep previous rows
        entries[pending[i].job.bookId] = FtsIndexEntry(
          rows: rows,
          source: pending[i].source,
        );
      }
      if (entries.isNotEmpty) _library.replaceBookFtsMany(entries);
      indexed += entries.length;
      pending.clear();
      // Let queued UI frames and timers run between batches.
      await Future<void>.delayed(Duration.zero);
    }

    for (final book in _library.allBooks(includeHidden: true)) {
      final id = book.id;
      if (id == null) continue;
      final source = FtsSource.of(book.path);
      if (!force && source != null) {
        final indexedFrom = _library.ftsSourceFor(id);
        if (indexedFrom != null && indexedFrom.matches(source)) continue;
      }
      pending.add((job: _jobFor(book), source: source));
      if (pending.length >= _batchSize) await flush();
    }
    await flush();
    return indexed;
  }

  /// Removes a book's FTS rows and indexed-state entry.
  void removeBook(int bookId) {
    _library.replaceBookFts(bookId, const []);
  }

  /// Searches indexed book content; delegates to [Library.searchBookContent].
  List<Map<String, Object?>> search(String query) =>
      _library.searchBookContent(query);
}

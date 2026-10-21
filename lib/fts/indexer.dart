import 'dart:convert';
import 'dart:io';

import '../core/db.dart';
import '../formats/epub.dart';
import '../formats/mobi.dart';
import '../formats/text_extract.dart';

/// Full-text indexer for book content.
///
/// Extracts chapter text from EPUB and MOBI books (PDFs are image-rendered
/// and skipped) and stores rows via [Library.replaceBookFts]. Indexed state
/// is tracked in `<library.baseDir>/fts-index-state.json` mapping bookId to
/// the indexed file's mtime+size, so unchanged books are skipped on
/// subsequent [indexAll] runs unless `force` is set.
class FtsIndexer {
  FtsIndexer(this._library);

  final Library _library;

  File get _stateFile =>
      File('${_library.baseDir}${Platform.pathSeparator}fts-index-state.json');

  Map<String, dynamic> _loadState() {
    final f = _stateFile;
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Corrupt state file — start fresh.
    }
    return <String, dynamic>{};
  }

  void _saveState(Map<String, dynamic> state) {
    _stateFile.writeAsStringSync(jsonEncode(state));
  }

  /// Signature of the book's indexable source file (mtime ms + size),
  /// or null when the book has no epub/mobi file.
  Map<String, int>? _fileSignature(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    final stat = f.statSync();
    return <String, int>{
      'mtimeMs': stat.modified.millisecondsSinceEpoch,
      'size': stat.size,
    };
  }

  /// Per-book extraction directory under `<baseDir>/.fts-extract`.
  Directory _extractDir(int bookId) => Directory(
      '${_library.baseDir}${Platform.pathSeparator}.fts-extract${Platform.pathSeparator}$bookId');

  /// Indexes a single book, replacing any previous FTS rows for it.
  ///
  /// Parse failures are logged and the book is skipped. Returns true when
  /// the book was (re-)indexed, false when it was skipped.
  Future<bool> indexBook(int bookId) async {
    final book = _library.getBook(bookId);
    if (book == null) return false;
    final rows = <Map<String, Object>>[];
    final formats = book.formats.map((e) => e.toLowerCase()).toList();

    if (formats.contains('epub')) {
      // Extract per book so concurrent/sequential books never share stale
      // content, and clean up afterwards to avoid disk accumulation.
      final extractDir = _extractDir(bookId);
      if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      try {
        final epub = EpubBook(book.path);
        final chapters = epub.chapters();
        epub.extractTo(extractDir.path);
        for (var i = 0; i < chapters.length; i++) {
          final (_, title) = chapters[i];
          final file = epub.chapterFile(extractDir.path, i);
          final html = await File(file).readAsString();
          rows.add({'chapter': i, 'title': title, 'content': htmlToText(html)});
        }
      } catch (e) {
        stderr.writeln('FtsIndexer: failed to index epub $bookId: $e');
        return false;
      } finally {
        if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      }
    } else if (formats.contains('mobi')) {
      // MOBI sectionHtml() extracts images into a fresh system-temp dir
      // that is never removed; route it into a per-book dir we clean up.
      final extractDir = _extractDir(bookId);
      if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      try {
        final mobi = MobiBook(book.path);
        final sections = mobi.sections();
        mobi.extractTo(extractDir.path);
        for (var i = 0; i < sections.length; i++) {
          rows.add({
            'chapter': i,
            'title': sections[i].$2,
            'content': htmlToText(mobi.sectionHtml(i)),
          });
        }
      } catch (e) {
        stderr.writeln('FtsIndexer: failed to index mobi $bookId: $e');
        return false;
      } finally {
        if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      }
    }
    // PDF and other formats: zero rows (image-rendered content).

    _library.replaceBookFts(bookId, rows);

    final state = _loadState();
    final sig = _fileSignature(book.path);
    if (sig != null) {
      state[bookId.toString()] = sig;
    } else {
      state.remove(bookId.toString());
    }
    _saveState(state);
    return true;
  }

  /// Indexes every book in the library. Books whose source file is unchanged
  /// since the last index are skipped unless [force] is true. Returns the
  /// number of books (re-)indexed.
  Future<int> indexAll({bool force = false}) async {
    final state = _loadState();
    var indexed = 0;
    for (final book in _library.allBooks(includeHidden: true)) {
      final id = book.id;
      if (id == null) continue;
      if (!force) {
        final sig = _fileSignature(book.path);
        final saved = state[id.toString()];
        if (sig != null &&
            saved is Map &&
            saved['mtimeMs'] == sig['mtimeMs'] &&
            saved['size'] == sig['size']) {
          continue; // unchanged
        }
      }
      try {
        if (await indexBook(id)) indexed++;
      } catch (e) {
        stderr.writeln('FtsIndexer: skipping book $id: $e');
      }
    }
    return indexed;
  }

  /// Removes a book's FTS rows and indexed-state entry.
  void removeBook(int bookId) {
    _library.replaceBookFts(bookId, const []);
    final state = _loadState();
    state.remove(bookId.toString());
    _saveState(state);
  }

  /// Searches indexed book content; delegates to [Library.searchBookContent].
  List<Map<String, Object?>> search(String query) =>
      _library.searchBookContent(query);
}

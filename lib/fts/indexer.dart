import 'dart:convert';
import 'dart:io';

import '../core/db.dart';
import '../core/models.dart';
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

  /// Extracts FTS rows for [book] from memory.
  ///
  /// Returns null when the file cannot be parsed; PDFs and other formats
  /// yield zero rows (their content is image-rendered).
  Future<List<Map<String, Object>>?> _extractRows(Book book) async {
    final rows = <Map<String, Object>>[];
    final formats = book.formats.map((e) => e.toLowerCase()).toList();
    try {
      if (formats.contains('epub')) {
        final epub = EpubBook(book.path);
        final chapters = epub.chapters();
        for (var i = 0; i < chapters.length; i++) {
          rows.add({
            'chapter': i,
            'title': chapters[i].$2,
            'content': htmlToText(epub.chapterSource(i)),
          });
        }
      } else if (formats.contains('mobi')) {
        final mobi = MobiBook(book.path);
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
      stderr.writeln('FtsIndexer: failed to index book ${book.id}: $e');
      return null;
    }
    return rows;
  }

  /// Records the indexed file signature in [state]; returns true if changed.
  bool _recordSignature(Map<String, dynamic> state, Book book) {
    final key = book.id.toString();
    final sig = _fileSignature(book.path);
    if (sig == null) {
      return state.remove(key) != null;
    }
    final saved = state[key];
    if (saved is Map &&
        saved['mtimeMs'] == sig['mtimeMs'] &&
        saved['size'] == sig['size']) {
      return false;
    }
    state[key] = sig;
    return true;
  }

  /// Indexes a single book, replacing any previous FTS rows for it.
  ///
  /// Parse failures are logged and the book is skipped. Returns true when
  /// the book was (re-)indexed, false when it was skipped.
  Future<bool> indexBook(int bookId) async {
    final book = _library.getBook(bookId);
    if (book == null) return false;
    final rows = await _extractRows(book);
    if (rows == null) return false;
    _library.replaceBookFts(bookId, rows);
    final state = _loadState();
    _recordSignature(state, book);
    _saveState(state);
    return true;
  }

  /// Indexes every book in the library. Books whose source file is unchanged
  /// since the last index are skipped unless [force] is true. Returns the
  /// number of books (re-)indexed.
  Future<int> indexAll({bool force = false}) async {
    final state = _loadState();
    final pending = <int, List<Map<String, Object>>>{};
    var stateDirty = false;
    for (final book in _library.allBooks(includeHidden: true)) {
      final id = book.id;
      if (id == null) continue;
      if (!force && !_needsIndex(state, book)) continue;
      final rows = await _extractRows(book);
      if (rows == null) continue; // parse failure: keep previous rows
      pending[id] = rows;
      stateDirty = _recordSignature(state, book) || stateDirty;
    }
    if (pending.isNotEmpty) _library.replaceBookFtsMany(pending);
    if (stateDirty) _saveState(state);
    return pending.length;
  }

  /// True when [book]'s file mtime/size differs from the recorded signature.
  bool _needsIndex(Map<String, dynamic> state, Book book) {
    final sig = _fileSignature(book.path);
    final saved = state[book.id.toString()];
    return sig == null ||
        saved is! Map ||
        saved['mtimeMs'] != sig['mtimeMs'] ||
        saved['size'] != sig['size'];
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

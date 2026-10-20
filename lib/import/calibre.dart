/// Read books from a calibre library folder (``metadata.db``).
///
/// Ports `vellum/core/calibre.py`. The calibre database is opened through a
/// writable snapshot in a temp dir; the source library is never modified.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/db.dart';
import '../core/models.dart';
import '../formats/text_extract.dart';

/// Formats the built-in reader can open, most preferred first.
const _preferredFormats = ['epub', 'pdf', 'mobi', 'azw3'];

/// Outcome of one calibre library import.
class CalibreImportResult {
  int added = 0;
  int skipped = 0;
  int failed = 0;
  String firstError = '';
}

/// Return true when [folder] contains a calibre ``metadata.db``.
bool isCalibreLibrary(String folder) =>
    File(p.join(folder, 'metadata.db')).existsSync();

/// Import every book from the calibre library in [folder].
///
/// Books already imported (matched by `Book.sourceId`) are skipped.
/// [progress], if given, is called as `progress(done, total)`.
Future<CalibreImportResult> importCalibreLibrary(
  Library library,
  String folder, {
  void Function(int done, int total)? progress,
}) async =>
    _importCalibreLibrary(library, folder, progress);

CalibreImportResult _importCalibreLibrary(
    Library library, String folder, void Function(int, int)? progress) {
  final root = Directory(folder).absolute.path;
  final dbPath = p.join(root, 'metadata.db');
  if (!File(dbPath).existsSync()) {
    throw ArgumentError('no metadata.db in $folder');
  }

  final db = _openDatabase(dbPath, _snapshotRoot(library));
  try {
    final conn = db.db;
    if (!_hasTable(conn, 'books')) {
      throw ArgumentError('$dbPath is not a calibre metadata database');
    }
    final bookCols = _columns(conn, 'books');
    const wanted = [
      'id', 'title', 'sort', 'isbn', 'pubdate', 'path', 'uuid', 'has_cover',
    ];
    final selected = wanted.where(bookCols.contains).toList();
    final total =
        conn.select('SELECT COUNT(*) FROM books').first.values.first as int;
    final rows =
        conn.select('SELECT ${selected.join(', ')} FROM books ORDER BY id');

    final result = CalibreImportResult();
    var done = 0;
    for (final row in rows) {
      done++;
      try {
        if (_importRow(conn, library, root, row, bookCols)) {
          result.added++;
        } else {
          result.skipped++;
        }
      } catch (e) {
        result.failed++;
        if (result.firstError.isEmpty) {
          result.firstError = '${e.runtimeType}: $e';
        }
      }
      if (progress != null && (done % 25 == 0 || done == total)) {
        progress(done, total);
      }
    }
    return result;
  } finally {
    db.close();
  }
}

// -- calibre database access -------------------------------------------------

class _OpenedDatabase {
  _OpenedDatabase(this.db, this.tempDir);

  final Database db;
  final Directory tempDir;

  void close() {
    try {
      db.dispose();
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort cleanup.
      }
    }
  }
}

/// Open a calibre database through a writable snapshot.
///
/// Copying `metadata.db` and its WAL sidecars into a private temporary
/// directory sidesteps locking, WAL, and read-only mounts; the calibre
/// library itself is never modified.
_OpenedDatabase _openDatabase(String dbPath, String? tempRoot) {
  Directory tempDir;
  try {
    tempDir = tempRoot != null
        ? Directory(tempRoot).createTempSync('vellum-calibre-')
        : Directory.systemTemp.createTempSync('vellum-calibre-');
  } on FileSystemException {
    tempDir = Directory.systemTemp.createTempSync('vellum-calibre-');
  }
  try {
    final dest = p.join(tempDir.path, 'metadata.db');
    _copy2(dbPath, dest);
    for (final suffix in ['-wal', '-shm']) {
      if (File('$dbPath$suffix').existsSync()) {
        _copy2('$dbPath$suffix', '$dest$suffix');
      }
    }
    final conn = sqlite3.open(dest);
    conn.execute('PRAGMA query_only = ON');
    return _OpenedDatabase(conn, tempDir);
  } catch (_) {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort cleanup.
    }
    rethrow;
  }
}

/// Like shutil.copy2: copy bytes plus modification/access times.
void _copy2(String src, String dst) {
  File(src).copySync(dst);
  final stat = File(src).statSync();
  File(dst)
    ..setLastModifiedSync(stat.modified)
    ..setLastAccessedSync(stat.accessed);
}

/// Prefer a disk-backed temp dir over a RAM-backed /tmp.
String? _snapshotRoot(Library library) {
  try {
    final root = p.join(library.baseDir, 'tmp', 'calibre');
    Directory(root).createSync(recursive: true);
    return root;
  } on FileSystemException {
    return null;
  }
}

bool _hasTable(Database conn, String name) => conn
    .select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
        [name])
    .isNotEmpty;

Set<String> _columns(Database conn, String table) => {
      for (final row in conn.select('PRAGMA table_info($table)'))
        row.values[1].toString(),
    };

List<String> _values(Database conn, String sql, int bookId) => [
      for (final row in conn.select(sql, [bookId]))
        if (row.values.first != null) row.values.first.toString(),
    ];

/// Run an optional calibre metadata query, falling back to [fallback].
///
/// Calibre schema details vary between versions and some libraries have
/// malformed or missing link tables. A single optional field must never
/// abort the import of an otherwise readable book.
T _optional<T>(T fallback, T Function() fn) {
  try {
    return fn();
  } catch (_) {
    return fallback;
  }
}

List<String> _authorNames(Database conn, int bookId) {
  if (!(_hasTable(conn, 'authors') &&
      _hasTable(conn, 'books_authors_link'))) {
    return [];
  }
  return _values(
    conn,
    'SELECT a.name FROM authors a'
    ' JOIN books_authors_link l ON l.author = a.id'
    ' WHERE l.book = ? ORDER BY l.id',
    bookId,
  );
}

List<String> _tagNames(Database conn, int bookId) {
  if (!(_hasTable(conn, 'tags') && _hasTable(conn, 'books_tags_link'))) {
    return [];
  }
  return _values(
    conn,
    'SELECT t.name FROM tags t'
    ' JOIN books_tags_link l ON l.tag = t.id'
    ' WHERE l.book = ? ORDER BY t.name',
    bookId,
  );
}

String _publisher(Database conn, int bookId) {
  if (!(_hasTable(conn, 'publishers') &&
      _hasTable(conn, 'books_publishers_link'))) {
    return '';
  }
  final names = _values(
    conn,
    'SELECT p.name FROM publishers p'
    ' JOIN books_publishers_link l ON l.publisher = p.id'
    ' WHERE l.book = ? ORDER BY l.id',
    bookId,
  );
  return names.isNotEmpty ? names.first : '';
}

String _language(Database conn, int bookId) {
  if (!(_hasTable(conn, 'languages') &&
      _hasTable(conn, 'books_languages_link'))) {
    return '';
  }
  final codes = _values(
    conn,
    'SELECT l.lang_code FROM languages l'
    ' JOIN books_languages_link bll ON bll.lang_code = l.id'
    ' WHERE bll.book = ? ORDER BY bll.id',
    bookId,
  );
  return codes.isNotEmpty ? codes.first : '';
}

String _description(Database conn, int bookId) {
  if (!_hasTable(conn, 'comments')) return '';
  final rows = _values(conn, 'SELECT text FROM comments WHERE book = ?', bookId);
  return rows.isNotEmpty ? htmlToText(rows.first) : '';
}

double _rating(Database conn, int bookId) {
  if (!(_hasTable(conn, 'ratings') &&
      _hasTable(conn, 'books_ratings_link'))) {
    return 0.0;
  }
  final rows = _values(
    conn,
    'SELECT r.rating FROM ratings r'
    ' JOIN books_ratings_link l ON l.rating = r.id'
    ' WHERE l.book = ?',
    bookId,
  );
  if (rows.isEmpty) return 0.0;
  final value = double.tryParse(rows.first);
  if (value == null) return 0.0;
  return (value / 2.0).clamp(0.0, 5.0);
}

String _isbn(Database conn, Row row, Set<String> bookCols) {
  if (_hasTable(conn, 'identifiers')) {
    final rows = _values(
      conn,
      "SELECT value FROM identifiers"
      " WHERE book = ? AND lower(type) = 'isbn' ORDER BY id",
      row['id'] as int,
    );
    if (rows.isNotEmpty) return rows.first.trim();
  }
  if (!bookCols.contains('isbn')) return '';
  return (row['isbn']?.toString() ?? '').trim();
}

/// Map lowercase format name to an existing file inside the library.
Map<String, String> _formatFiles(
    Database conn, String root, int bookId, String bookPath) {
  if (!_hasTable(conn, 'data')) return {};
  if (!_columns(conn, 'data').containsAll({'book', 'format', 'name'})) {
    return {};
  }
  final bookDir = _joinInside(root, [bookPath]);
  if (bookDir.isEmpty || !Directory(bookDir).existsSync()) return {};
  final List<FileSystemEntity> entries;
  try {
    entries = Directory(bookDir).listSync();
  } on FileSystemException {
    return {};
  }
  final byLower = {
    for (final e in entries) p.basename(e.path).toLowerCase(): p.basename(e.path),
  };

  final found = <String, String>{};
  for (final row
      in conn.select('SELECT format, name FROM data WHERE book = ?', [bookId])) {
    final fmt = (row['format']?.toString() ?? '').trim().toLowerCase();
    final base = p.basename((row['name']?.toString() ?? '').trim());
    if (fmt.isEmpty || base.isEmpty) continue;
    final filename = byLower['$base.$fmt'.toLowerCase()];
    if (filename != null) found[fmt] = p.join(bookDir, filename);
  }
  return found;
}

String _coverFile(String root, String bookPath, Object? hasCover) {
  if (hasCover == null || hasCover == 0 || hasCover == false) return '';
  final bookDir = _joinInside(root, [bookPath]);
  if (bookDir.isEmpty) return '';
  for (final name in ['cover.jpg', 'cover.jpeg', 'cover.png']) {
    final candidate = p.join(bookDir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return '';
}

/// Join [parts] to [root], refusing paths outside the library.
String _joinInside(String root, List<String> parts) {
  final candidate = p.normalize(p.absolute(p.joinAll([root, ...parts])));
  final rootAbs = p.normalize(p.absolute(root));
  if (candidate != rootAbs && !candidate.startsWith('$rootAbs${p.separator}')) {
    return '';
  }
  return candidate;
}

String _pubdate(Object? value) {
  final text = (value?.toString() ?? '').trim();
  final match = RegExp(r'^(\d{4})').firstMatch(text);
  return match != null ? match.group(1)! : text;
}

/// Import one calibre row; return false if it is already present.
bool _importRow(Database conn, Library library, String root, Row row,
    Set<String> bookCols) {
  final bookId = row['id'] as int;
  final uuid = bookCols.contains('uuid')
      ? (row['uuid']?.toString() ?? '').trim()
      : '';
  final sourceId = uuid.isNotEmpty ? 'calibre:$uuid' : 'calibre:$root:$bookId';
  if (library.findBySourceId(sourceId) != null) return false;

  final bookPath = row['path']?.toString() ?? '';
  final files = _optional(
      <String, String>{}, () => _formatFiles(conn, root, bookId, bookPath));
  var preferred = '';
  for (final fmt in _preferredFormats) {
    if (files.containsKey(fmt)) {
      preferred = files[fmt]!;
      break;
    }
  }
  if (preferred.isEmpty && files.isNotEmpty) preferred = files.values.first;
  final hasCover = bookCols.contains('has_cover') ? row['has_cover'] : null;

  final title = (row['title']?.toString() ?? '').trim();
  final book = Book(
    title: title.isEmpty ? 'Untitled' : title,
    sort: bookCols.contains('sort') ? (row['sort']?.toString() ?? '').trim() : '',
    authors: _optional(<String>[], () => _authorNames(conn, bookId)),
    isbn: _optional('', () => _isbn(conn, row, bookCols)),
    publisher: _optional('', () => _publisher(conn, bookId)),
    pubdate: _pubdate(bookCols.contains('pubdate') ? row['pubdate'] : null),
    language: _optional('', () => _language(conn, bookId)),
    description: _optional('', () => _description(conn, bookId)),
    tags: _optional(<String>[], () => _tagNames(conn, bookId)),
    formats: files.keys.toList()..sort(),
    coverPath: _coverFile(root, bookPath, hasCover),
    path: preferred,
    rating: _optional(0.0, () => _rating(conn, bookId)),
    sourceId: sourceId,
  );
  library.addBook(book);
  return true;
}

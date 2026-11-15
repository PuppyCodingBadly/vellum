/// SQLite-backed library catalogue.
///
/// Ports `vellum/core/db.py` (class Library) to Dart using package:sqlite3.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'ink.dart';
import 'models.dart';

/// Case-folds [value] for catalogue matching.
///
/// SQLite's `lower()` folds only ASCII, so a non-ASCII capital such as `Ä`
/// never matched a lower-case query. Catalogue search and the FTS fallback
/// fold both the stored column and the query through this one function,
/// exposed to SQL as `vellum_fold`.
String foldText(String value) => value.toLowerCase();

/// The library database. Use `:memory:` for an in-memory database.
///
/// Both in-memory and file-backed libraries keep one persistent connection
/// with `PRAGMA foreign_keys = ON`.
class Library {
  final String path;

  /// Live connection; null once [close] ran.
  Database? _connection;

  /// The connection, rejecting use after [close] instead of writing to a
  /// disposed handle (or, worse, the previous library file).
  Database get _db {
    final connection = _connection;
    if (connection == null) {
      throw StateError('Library $path is closed');
    }
    return connection;
  }

  /// Whether the FTS5 module is available; when false a plain fallback
  /// `book_fts` table is used instead.
  bool ftsAvailable = true;

  /// Whether the sqlite dynamic library override has been installed.
  static bool _sqliteOverrideInstalled = false;

  /// Opens the system sqlite3 library, falling back to the versioned
  /// soname when the unversioned dev symlink is missing.
  static DynamicLibrary _openSqlite() {
    try {
      return DynamicLibrary.open('libsqlite3.so');
    } on ArgumentError {
      return DynamicLibrary.open('libsqlite3.so.0');
    }
  }

  /// Installs the sqlite dynamic library override exactly once.
  static void _ensureSqliteOverride() {
    if (_sqliteOverrideInstalled) return;
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, _openSqlite);
    }
    _sqliteOverrideInstalled = true;
  }

  Library(this.path) {
    _ensureSqliteOverride();
    _connection = path == ':memory:'
        ? sqlite3.openInMemory()
        : sqlite3.open(path);
    if (path != ':memory:') {
      // One writer plus concurrent readers; NORMAL is durable enough for a
      // catalogue and removes an fsync per commit.
      _db.execute('PRAGMA journal_mode = WAL');
      _db.execute('PRAGMA synchronous = NORMAL');
    }
    _db.execute('PRAGMA foreign_keys = ON');
    // Catalogue search folds with Dart on both sides; SQLite's built-in
    // lower() is ASCII-only.
    _db.createFunction(
      functionName: 'vellum_fold',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      function: (arguments) {
        final value = arguments.first;
        return value is String ? foldText(value) : value;
      },
    );
    _createSchema();
    _migrate();
    _write(_createIndexes);
  }

  /// Secondary indexes; created after migrations so old databases that lack
  /// the `hidden` column can be upgraded first.
  void _createIndexes() {
    _db.execute(_indexSchema);
  }

  static const _indexSchema = '''
CREATE INDEX IF NOT EXISTS books_title ON books(title);
CREATE INDEX IF NOT EXISTS books_hidden_title ON books(hidden, title);
CREATE INDEX IF NOT EXISTS book_authors_book ON book_authors(book_id);
CREATE INDEX IF NOT EXISTS book_tags_book ON book_tags(book_id);
CREATE INDEX IF NOT EXISTS formats_book ON formats(book_id);
CREATE INDEX IF NOT EXISTS highlights_book ON highlights(book_id);
CREATE INDEX IF NOT EXISTS reading_sessions_book ON reading_sessions(book_id);
CREATE INDEX IF NOT EXISTS shelf_books_book ON shelf_books(book_id);
CREATE INDEX IF NOT EXISTS ink_strokes_book_chapter
    ON ink_strokes(book_id, chapter);
''';

  /// Directory covers etc. live next to: cwd for `:memory:`, otherwise the
  /// parent of the resolved database path.
  String get baseDir {
    if (path == ':memory:') return Directory.current.path;
    return File(path).absolute.parent.path;
  }

  /// Closes the connection; idempotent.
  ///
  /// Every later operation throws [StateError] rather than touching a disposed
  /// handle, so a stale [Library] reference fails loudly instead of silently
  /// writing to the wrong database.
  void close() {
    final connection = _connection;
    if (connection == null) return;
    _connection = null;
    connection.dispose();
  }

  static const _schema = '''
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
    progress REAL NOT NULL DEFAULT 0,
    updated TEXT NOT NULL
);
''';

  static const _extraSchema = '''
CREATE TABLE IF NOT EXISTS shelves (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS shelf_books (
    shelf_id INTEGER NOT NULL REFERENCES shelves(id) ON DELETE CASCADE,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    PRIMARY KEY (shelf_id, book_id)
);
CREATE TABLE IF NOT EXISTS reading_sessions (
    id INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    started TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    end_locator TEXT NOT NULL DEFAULT ''
);
-- Skip state for the full-text index. It lives beside the rows it describes
-- and cascades with the book, so a deleted (or re-imported) book can never
-- keep a stale "already indexed" mark.
CREATE TABLE IF NOT EXISTS fts_index_state (
    book_id INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    path TEXT NOT NULL DEFAULT '',
    mtime_ms INTEGER NOT NULL DEFAULT 0,
    size INTEGER NOT NULL DEFAULT 0
);
''';

  /// Handwriting strokes, anchored to a book's chapter and a page rectangle.
  ///
  /// Created by [_migrate] rather than [_createSchema]: installed libraries
  /// predate it, while fresh ones run the same migration, so the definition
  /// exists once.
  static const _inkSchema = '''
CREATE TABLE IF NOT EXISTS ink_strokes (
    id INTEGER PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    chapter INTEGER NOT NULL,
    kind TEXT NOT NULL,
    start INTEGER NOT NULL DEFAULT 0,
    end INTEGER NOT NULL DEFAULT 0,
    rect TEXT NOT NULL,
    color INTEGER NOT NULL,
    width REAL NOT NULL,
    points BLOB NOT NULL,
    created TEXT NOT NULL
);
''';

  void _createSchema() {
    _db.execute('BEGIN');
    try {
      _db.execute(_schema);
      _db.execute(_extraSchema);
      try {
        _db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(book_id UNINDEXED, chapter UNINDEXED, title, content)',
        );
        ftsAvailable = true;
      } catch (_) {
        ftsAvailable = false;
        _db.execute(
          'CREATE TABLE IF NOT EXISTS book_fts (book_id INTEGER, chapter INTEGER, title TEXT, content TEXT)',
        );
      }
      // A pre-existing plain book_fts table (or a failed FTS5 create above)
      // means MATCH queries are unavailable; use the LIKE fallback.
      final sqlRow = _db.select(
        "SELECT sql FROM sqlite_master WHERE name = 'book_fts'",
      );
      if (sqlRow.isEmpty ||
          !(sqlRow.first['sql'] as String).toUpperCase().contains('VIRTUAL')) {
        ftsAvailable = false;
        if (sqlRow.isEmpty) {
          _db.execute(
            'CREATE TABLE IF NOT EXISTS book_fts (book_id INTEGER, chapter INTEGER, title TEXT, content TEXT)',
          );
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrate() {
    final cols = {
      for (final row in _db.select('PRAGMA table_info(books)'))
        row['name'] as String,
    };
    if (!cols.contains('hidden')) {
      _db.execute(
        'ALTER TABLE books ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!cols.contains('source_id')) {
      _db.execute(
        "ALTER TABLE books ADD COLUMN source_id TEXT NOT NULL DEFAULT ''",
      );
    }
    final positionCols = {
      for (final row in _db.select('PRAGMA table_info(reading_positions)'))
        row['name'] as String,
    };
    if (positionCols.isNotEmpty && !positionCols.contains('progress')) {
      _db.execute(
        'ALTER TABLE reading_positions ADD COLUMN progress REAL NOT NULL DEFAULT 0',
      );
    }
    // Ink annotations postdate the first library files; this upgrades an
    // existing catalogue in place and is a no-op afterwards.
    _db.execute(_inkSchema);
  }

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// Wraps [fn] in the one transaction currently open; callers never nest.
  ///
  /// There is deliberately no savepoint nesting: a failed COMMIT used to
  /// leave the depth counter decremented twice and hide the real error.
  T _write<T>(T Function() fn) {
    _db.execute('BEGIN');
    try {
      final result = fn();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        _db.execute('ROLLBACK');
      } catch (_) {
        // COMMIT can fail after closing the transaction; the original error
        // is the one worth reporting.
      }
      rethrow;
    }
  }

  int _getOrInsertAuthor(String name) {
    final stmt = _db.prepare('SELECT id FROM authors WHERE name = ?');
    try {
      final rows = stmt.select([name]);
      if (rows.isNotEmpty) return rows.first['id'] as int;
    } finally {
      stmt.dispose();
    }
    _db.execute('INSERT INTO authors (name) VALUES (?)', [name]);
    return _db.lastInsertRowId;
  }

  int _getOrInsertTag(String name) {
    final stmt = _db.prepare('SELECT id FROM tags WHERE name = ?');
    try {
      final rows = stmt.select([name]);
      if (rows.isNotEmpty) return rows.first['id'] as int;
    } finally {
      stmt.dispose();
    }
    _db.execute('INSERT INTO tags (name) VALUES (?)', [name]);
    return _db.lastInsertRowId;
  }

  /// Rewrites author/tag/format links for [book] (book must have an id).
  void _writeLinks(Book book) {
    final id = book.id!;
    _db.execute('DELETE FROM book_authors WHERE book_id = ?', [id]);
    _db.execute('DELETE FROM book_tags WHERE book_id = ?', [id]);
    _db.execute('DELETE FROM formats WHERE book_id = ?', [id]);
    for (var i = 0; i < book.authors.length; i++) {
      final authorId = _getOrInsertAuthor(book.authors[i]);
      _db.execute(
        'INSERT INTO book_authors (book_id, author_id, position) VALUES (?, ?, ?)',
        [id, authorId, i],
      );
    }
    for (final tag in book.tags) {
      final tagId = _getOrInsertTag(tag);
      _db.execute('INSERT INTO book_tags (book_id, tag_id) VALUES (?, ?)', [
        id,
        tagId,
      ]);
    }
    for (final fmt in book.formats) {
      _db.execute(
        'INSERT INTO formats (book_id, format, path) VALUES (?, ?, ?)',
        [id, fmt, book.path],
      );
    }
  }

  /// Adds [book] and returns its new id (also set on [book.id]).
  int addBook(Book book) => _write(() => _insertBook(book));

  /// Adds [books] in one transaction and returns their new ids.
  List<int> addBooks(List<Book> books) =>
      _write(() => [for (final book in books) _insertBook(book)]);

  int _insertBook(Book book) {
    if (book.added.isEmpty) book.added = _nowIso();
    _db.execute(
      'INSERT INTO books (title, sort, isbn, publisher, pubdate, language, '
      'description, cover_path, path, rating, added, hidden, source_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        book.title,
        book.sort,
        book.isbn,
        book.publisher,
        book.pubdate,
        book.language,
        book.description,
        book.coverPath,
        book.path,
        book.rating,
        book.added,
        book.hidden ? 1 : 0,
        book.sourceId,
      ],
    );
    book.id = _db.lastInsertRowId;
    _writeLinks(book);
    return book.id!;
  }

  /// Updates an existing book. Throws [ArgumentError] when [book.id] is null
  /// and [StateError] when no row with that id exists.
  void updateBook(Book book) {
    if (book.id == null) {
      throw ArgumentError('book has no id');
    }
    _write(() {
      final stmt = _db.prepare(
        'UPDATE books SET title=?, sort=?, isbn=?, publisher=?, pubdate=?, '
        'language=?, description=?, cover_path=?, path=?, rating=?, added=?, '
        'hidden=?, source_id=? WHERE id=?',
      );
      int changed;
      try {
        stmt.execute([
          book.title,
          book.sort,
          book.isbn,
          book.publisher,
          book.pubdate,
          book.language,
          book.description,
          book.coverPath,
          book.path,
          book.rating,
          book.added,
          book.hidden ? 1 : 0,
          book.sourceId,
          book.id,
        ]);
        changed = _db.updatedRows;
      } finally {
        stmt.dispose();
      }
      if (changed == 0) {
        throw StateError('no book with id ${book.id}');
      }
      _writeLinks(book);
    });
  }

  Book? _hydrate(ResultSet rows) {
    if (rows.isEmpty) return null;
    return _rowToBook(rows.first);
  }

  Book _rowToBook(Row row) => _rowsToBooks([row]).single;

  /// Hydrates [rows] with three batched IN queries: O(1) statements per page
  /// of books instead of three per book.
  List<Book> _rowsToBooks(List<Row> rows) {
    if (rows.isEmpty) return const <Book>[];
    final ids = [for (final row in rows) row['id'] as int];
    final authors = <int, List<String>>{};
    final tags = <int, List<String>>{};
    final formats = <int, List<String>>{};
    final progress = <int, double>{};
    // Stay below SQLite's variable limit on every build.
    const chunkSize = 500;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final chunk = ids.sublist(
        start,
        start + chunkSize > ids.length ? ids.length : start + chunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      for (final r in _db.select(
        'SELECT ba.book_id AS book_id, a.name AS name '
        'FROM book_authors ba JOIN authors a ON a.id = ba.author_id '
        'WHERE ba.book_id IN ($placeholders) '
        'ORDER BY ba.book_id, ba.position',
        chunk,
      )) {
        (authors[r['book_id'] as int] ??= <String>[]).add(r['name'] as String);
      }
      for (final r in _db.select(
        'SELECT bt.book_id AS book_id, t.name AS name '
        'FROM book_tags bt JOIN tags t ON t.id = bt.tag_id '
        'WHERE bt.book_id IN ($placeholders) '
        'ORDER BY bt.book_id, t.name',
        chunk,
      )) {
        (tags[r['book_id'] as int] ??= <String>[]).add(r['name'] as String);
      }
      for (final r in _db.select(
        'SELECT book_id, format FROM formats '
        'WHERE book_id IN ($placeholders) ORDER BY book_id, format',
        chunk,
      )) {
        (formats[r['book_id'] as int] ??= <String>[]).add(
          r['format'] as String,
        );
      }
      for (final r in _db.select(
        'SELECT book_id, progress FROM reading_positions '
        'WHERE book_id IN ($placeholders)',
        chunk,
      )) {
        progress[r['book_id'] as int] = (r['progress'] as num).toDouble();
      }
    }
    return [
      for (final row in rows)
        Book(
          id: row['id'] as int,
          title: row['title'] as String,
          authors: authors[row['id']] ?? const <String>[],
          sort: row['sort'] as String,
          isbn: row['isbn'] as String,
          publisher: row['publisher'] as String,
          pubdate: row['pubdate'] as String,
          language: row['language'] as String,
          description: row['description'] as String,
          tags: tags[row['id']] ?? const <String>[],
          formats: formats[row['id']] ?? const <String>[],
          coverPath: row['cover_path'] as String,
          path: row['path'] as String,
          rating: (row['rating'] as num).toDouble(),
          added: row['added'] as String,
          hidden: (row['hidden'] as int) != 0,
          sourceId: row['source_id'] as String,
          progress: progress[row['id'] as int] ?? 0.0,
        ),
    ];
  }

  /// Returns the book with [id], or null.
  Book? getBook(int id) =>
      _hydrate(_db.select('SELECT * FROM books WHERE id = ?', [id]));

  /// All books, ordered by title. Hidden books excluded unless
  /// [includeHidden].
  List<Book> allBooks({bool includeHidden = false}) {
    final sql = includeHidden
        ? 'SELECT * FROM books ORDER BY title'
        : 'SELECT * FROM books WHERE hidden = 0 ORDER BY title';
    return _rowsToBooks(_db.select(sql));
  }

  /// Escapes LIKE metacharacters so a literal `%`/`_`/`\` matches itself.
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Searches the library. Empty/whitespace query returns [allBooks].
  /// Whitespace-separated tokens are ANDed; each token matches
  /// case-insensitively against title, isbn, author name, or tag name.
  List<Book> search(String query, {bool includeHidden = false}) {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return allBooks(includeHidden: includeHidden);
    const perToken = r'''
(vellum_fold(b.title) LIKE ? ESCAPE '\' OR vellum_fold(b.isbn) LIKE ? ESCAPE '\'
 OR EXISTS (SELECT 1 FROM book_authors ba JOIN authors a ON a.id = ba.author_id
   WHERE ba.book_id = b.id AND vellum_fold(a.name) LIKE ? ESCAPE '\')
 OR EXISTS (SELECT 1 FROM book_tags bt JOIN tags t ON t.id = bt.tag_id
   WHERE bt.book_id = b.id AND vellum_fold(t.name) LIKE ? ESCAPE '\'))''';
    final where = tokens.map((_) => perToken).join(' AND ');
    final sql =
        'SELECT b.* FROM books b WHERE $where'
        '${includeHidden ? '' : ' AND b.hidden = 0'} ORDER BY b.title';
    final params = [
      for (final token in tokens)
        ...List.filled(4, '%${_escapeLike(foldText(token))}%'),
    ];
    return _rowsToBooks(_db.select(sql, params));
  }

  /// Deletes a book; children rows cascade.
  void deleteBook(int id) {
    _write(() {
      // book_fts (FTS5 virtual table) has no FK cascade; clean it explicitly.
      _db.execute('DELETE FROM book_fts WHERE book_id = ?', [id]);
      _db.execute('DELETE FROM books WHERE id = ?', [id]);
    });
  }

  /// Deletes books with no path whose title is in [titles] and which have no
  /// format rows. Returns the number deleted; hidden books are deleted too.
  int deleteBooksWithoutFiles(Set<String> titles) {
    if (titles.isEmpty) return 0;
    return _write(() {
      var total = 0;
      for (final title in titles) {
        // book_fts (FTS5 virtual table) has no FK cascade; clean it explicitly.
        final ids = _db
            .select(
              "SELECT id FROM books WHERE path='' AND title = ? "
              'AND NOT EXISTS (SELECT 1 FROM formats f WHERE f.book_id=books.id)',
              [title],
            )
            .map((r) => r['id'] as int)
            .toList();
        for (final id in ids) {
          _db.execute('DELETE FROM book_fts WHERE book_id = ?', [id]);
          _db.execute('DELETE FROM books WHERE id = ?', [id]);
        }
        total += ids.length;
      }
      return total;
    });
  }

  /// Sets the hidden flag. Throws [StateError] when no such book exists.
  void setHidden(int id, bool hidden) {
    _write(() {
      _db.execute('UPDATE books SET hidden = ? WHERE id = ?', [
        hidden ? 1 : 0,
        id,
      ]);
      if (_db.updatedRows == 0) {
        throw StateError('no book with id $id');
      }
    });
  }

  /// Finds the first book with the given [sourceId]; null for falsy input.
  Book? findBySourceId(String sourceId) {
    if (sourceId.isEmpty) return null;
    return _hydrate(
      _db.select(
        'SELECT * FROM books WHERE source_id = ? ORDER BY id LIMIT 1',
        [sourceId],
      ),
    );
  }

  /// Adds a highlight and returns its id.
  int addHighlight(int bookId, String position, String color, String text) {
    return _write(() {
      _db.execute(
        'INSERT INTO highlights (book_id, position, color, text, created) '
        'VALUES (?, ?, ?, ?, ?)',
        [bookId, position, color, text, _nowIso()],
      );
      return _db.lastInsertRowId;
    });
  }

  /// Lists highlights for [bookId] ordered by created, id.
  List<Map<String, Object?>> listHighlights(int bookId) {
    return _db
        .select(
          'SELECT id, book_id, position, color, text, created FROM highlights '
          'WHERE book_id = ? ORDER BY created, id',
          [bookId],
        )
        .map((r) => Map<String, Object?>.of(r))
        .toList();
  }

  void deleteHighlight(int id) {
    _write(() {
      _db.execute('DELETE FROM highlights WHERE id = ?', [id]);
    });
  }

  void setReadingPosition(int bookId, String locator, {double progress = 0.0}) {
    final fraction = progress.isFinite
        ? progress.clamp(0.0, 1.0).toDouble()
        : 0.0;
    _write(() {
      _db.execute(
        'INSERT OR REPLACE INTO reading_positions '
        '(book_id, locator, progress, updated) VALUES (?, ?, ?, ?)',
        [bookId, locator, fraction, _nowIso()],
      );
    });
  }

  String? getReadingPosition(int bookId) {
    final rows = _db.select(
      'SELECT locator FROM reading_positions WHERE book_id = ?',
      [bookId],
    );
    if (rows.isEmpty) return null;
    return rows.first['locator'] as String;
  }

  // ---- Ink annotations ----

  /// Strokes of [bookId] in [chapter], oldest first.
  List<InkStroke> listInkStrokes(int bookId, int chapter) => _inkStrokes(
    'SELECT * FROM ink_strokes WHERE book_id = ? AND chapter = ? ORDER BY id',
    [bookId, chapter],
  );

  /// Every stroke of [bookId], chapter by chapter.
  List<InkStroke> listInkStrokesForBook(int bookId) => _inkStrokes(
    'SELECT * FROM ink_strokes WHERE book_id = ? ORDER BY chapter, id',
    [bookId],
  );

  List<InkStroke> _inkStrokes(String sql, List<Object?> params) =>
      _db.select(sql, params).map(_rowToInkStroke).toList();

  /// Rebuilds a stroke through [InkAnchor.fromJson], so a row written by an
  /// older or newer build fails the same way a JSON document would.
  static InkStroke _rowToInkStroke(Row row) {
    final anchor = InkAnchor.fromJson({
      'kind': row['kind'],
      'chapter': row['chapter'],
      'start': row['start'],
      'end': row['end'],
      ..._anchorGeometryFromColumn(jsonDecode(row['rect'] as String)),
    });
    final decoded = InkCodec.decodePoints(row['points'] as Uint8List);
    return InkStroke(
      id: row['id'] as int,
      anchor: anchor,
      color: row['color'] as int,
      width: (row['width'] as num).toDouble(),
      points: decoded.points,
      lineIndices: decoded.lineIndices.isEmpty ? null : decoded.lineIndices,
    );
  }

  /// The `rect` column holds `[left, top, width, height]`, as it always has.
  /// Per-line boxes ride along in the same value as `{"rect": ..., "lines":
  /// ...}`, which only rows that need them use; an anchor without lines keeps
  /// writing the bare legacy array.
  static String _anchorRectColumn(InkAnchor anchor) {
    final json = anchor.toJson();
    if (anchor.lines.isEmpty) return jsonEncode(json['rect']);
    return jsonEncode({'rect': json['rect'], 'lines': json['lines']});
  }

  /// Reads either the legacy bare rect array or the line-bearing object.
  static Map<String, Object?> _anchorGeometryFromColumn(Object? stored) {
    if (stored is List) return {'rect': stored};
    if (stored is Map) {
      return {
        'rect': stored['rect'],
        if (stored['lines'] != null) 'lines': stored['lines'],
      };
    }
    throw FormatException('ink rect column must hold a rect or line geometry');
  }

  /// Inserts [stroke] for [bookId] and returns its id, also set on [stroke].
  int addInkStroke(int bookId, InkStroke stroke) {
    final anchor = stroke.anchor;
    final rectJson = _anchorRectColumn(anchor);
    // Line indices live in the point BLOB; a stroke without them keeps the
    // compact legacy triples instead of a header of zeroes.
    final lineIndices = stroke.lineIndices;
    final points = lineIndices == null
        ? Uint8List.view(
            stroke.points.buffer,
            stroke.points.offsetInBytes,
            stroke.points.lengthInBytes,
          )
        : InkCodec.encodePoints(
            [for (var i = 0; i < stroke.pointCount; i++) stroke.pointAt(i)],
            [for (var i = 0; i < stroke.pointCount; i++) stroke.pressureAt(i)],
            lineIndices,
          );
    final id = _write(() {
      _db.execute(
        'INSERT INTO ink_strokes '
        '(book_id, chapter, kind, start, end, rect, color, width, points, '
        'created) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          bookId,
          anchor.chapter,
          anchor.kind.name,
          anchor.start,
          anchor.end,
          rectJson,
          stroke.color,
          stroke.width,
          points,
          _nowIso(),
        ],
      );
      return _db.lastInsertRowId;
    });
    stroke.id = id;
    return id;
  }

  void deleteInkStroke(int id) {
    _write(() {
      _db.execute('DELETE FROM ink_strokes WHERE id = ?', [id]);
    });
  }

  // ---- Shelves (new feature) ----

  /// Creates a shelf and returns its id.
  int createShelf(String name) {
    return _write(() {
      _db.execute('INSERT INTO shelves (name) VALUES (?)', [name]);
      return _db.lastInsertRowId;
    });
  }

  void renameShelf(int id, String name) {
    _write(() {
      _db.execute('UPDATE shelves SET name = ? WHERE id = ?', [name, id]);
    });
  }

  void deleteShelf(int id) {
    _write(() {
      _db.execute('DELETE FROM shelves WHERE id = ?', [id]);
    });
  }

  /// All shelves as `{id, name, book_count}` maps ordered by name.
  List<Map<String, Object?>> listShelves() {
    return _db
        .select(
          'SELECT s.id AS id, s.name AS name, '
          '(SELECT COUNT(*) FROM shelf_books sb WHERE sb.shelf_id = s.id) '
          'AS book_count FROM shelves s ORDER BY s.name',
        )
        .map((r) => Map<String, Object?>.of(r))
        .toList();
  }

  void addBookToShelf(int shelfId, int bookId) {
    _write(() {
      _db.execute(
        'INSERT OR IGNORE INTO shelf_books (shelf_id, book_id) VALUES (?, ?)',
        [shelfId, bookId],
      );
    });
  }

  void removeBookFromShelf(int shelfId, int bookId) {
    _write(() {
      _db.execute(
        'DELETE FROM shelf_books WHERE shelf_id = ? AND book_id = ?',
        [shelfId, bookId],
      );
    });
  }

  /// Books on a shelf, ordered by title.
  List<Book> shelfBooks(int shelfId, {bool includeHidden = false}) {
    final sql =
        'SELECT b.* FROM books b '
        'JOIN shelf_books sb ON sb.book_id = b.id '
        'WHERE sb.shelf_id = ?'
        '${includeHidden ? '' : ' AND b.hidden = 0'} ORDER BY b.title';
    return _rowsToBooks(_db.select(sql, [shelfId]));
  }

  /// Ids of shelves containing [bookId].
  List<int> shelvesForBook(int bookId) {
    return _db
        .select(
          'SELECT shelf_id FROM shelf_books WHERE book_id = ? ORDER BY shelf_id',
          [bookId],
        )
        .map((r) => r['shelf_id'] as int)
        .toList();
  }

  // ---- Reading stats (new feature) ----

  void addReadingSession(
    int bookId,
    String startedIso,
    int durationSeconds,
    String endLocator,
  ) {
    _write(() {
      _db.execute(
        'INSERT INTO reading_sessions (book_id, started, duration_seconds, end_locator) '
        'VALUES (?, ?, ?, ?)',
        [bookId, startedIso, durationSeconds, endLocator],
      );
    });
  }

  /// Per-book stats: `{totalSeconds, sessions, lastRead}`.
  Map<String, Object?> statsForBook(int bookId) {
    final rows = _db.select(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(*) AS sessions, MAX(started) AS last_read '
      'FROM reading_sessions WHERE book_id = ?',
      [bookId],
    );
    final r = rows.first;
    return {
      'totalSeconds': r['total_seconds'],
      'sessions': r['sessions'],
      'lastRead': r['last_read'],
    };
  }

  /// Library-wide stats: `{totalSeconds, booksRead, sessions}`.
  Map<String, Object?> libraryStats() {
    final rows = _db.select(
      'SELECT COALESCE(SUM(duration_seconds), 0) AS total_seconds, '
      'COUNT(DISTINCT book_id) AS books_read, COUNT(*) AS sessions '
      'FROM reading_sessions',
    );
    final r = rows.first;
    return {
      'totalSeconds': r['total_seconds'],
      'booksRead': r['books_read'],
      'sessions': r['sessions'],
    };
  }

  /// Most recent reading sessions as `{id, book_id, started,
  /// duration_seconds, end_locator}` maps, newest first.
  List<Map<String, Object?>> recentReadingSessions(int limit) {
    return _db
        .select(
          'SELECT id, book_id, started, duration_seconds, end_locator '
          'FROM reading_sessions ORDER BY id DESC LIMIT ?',
          [limit],
        )
        .map((r) => Map<String, Object?>.of(r))
        .toList();
  }

  // ---- Full-text search over book content (new feature) ----

  /// Replaces the FTS rows for [bookId] with [rows].
  ///
  /// [source] is the file signature the rows were extracted from; it is
  /// stored in the same transaction so a skip decision can never outlive the
  /// rows it describes. Null clears the recorded signature.
  void replaceBookFts(
    int bookId,
    List<Map<String, Object>> rows, {
    FtsSource? source,
  }) {
    _write(() => _replaceFtsRows(bookId, rows, source));
  }

  /// Replaces FTS rows for many books in one transaction (indexing runs).
  void replaceBookFtsMany(Map<int, FtsIndexEntry> entries) {
    _write(() {
      for (final entry in entries.entries) {
        _replaceFtsRows(entry.key, entry.value.rows, entry.value.source);
      }
    });
  }

  /// The signature recorded alongside [bookId]'s FTS rows, or null when the
  /// book has never been indexed.
  FtsSource? ftsSourceFor(int bookId) {
    final rows = _db.select(
      'SELECT path, mtime_ms, size FROM fts_index_state WHERE book_id = ?',
      [bookId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return FtsSource(
      path: row['path'] as String,
      mtimeMs: row['mtime_ms'] as int,
      size: row['size'] as int,
    );
  }

  void _replaceFtsRows(
    int bookId,
    List<Map<String, Object>> rows,
    FtsSource? source,
  ) {
    _db.execute('DELETE FROM book_fts WHERE book_id = ?', [bookId]);
    for (final r in rows) {
      _db.execute(
        'INSERT INTO book_fts (book_id, chapter, title, content) '
        'VALUES (?, ?, ?, ?)',
        [
          bookId,
          r['chapter'] as int,
          r['title'] as String,
          r['content'] as String,
        ],
      );
    }
    _db.execute('DELETE FROM fts_index_state WHERE book_id = ?', [bookId]);
    if (source != null) {
      // Guarded insert: indexing runs while other actions may delete a book,
      // and a missing parent must skip the state row instead of failing the
      // whole batch on the foreign key.
      _db.execute(
        'INSERT INTO fts_index_state (book_id, path, mtime_ms, size) '
        'SELECT ?, ?, ?, ? WHERE EXISTS '
        '(SELECT 1 FROM books WHERE id = ?)',
        [bookId, source.path, source.mtimeMs, source.size, bookId],
      );
    }
  }

  /// Sanitizes a raw query into an FTS5 MATCH expression: tokens wrapped in
  /// double quotes, joined with AND.
  static String _sanitizeMatch(String query) {
    final tokens = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '""')}"');
    return tokens.join(' AND ');
  }

  /// Searches indexed book content. Returns `{book_id, chapter, title,
  /// snippet}` maps, at most [limit] of them. Uses FTS5 when available, else
  /// a LIKE fallback.
  List<Map<String, Object?>> searchBookContent(String query, {int limit = 20}) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final maxRows = limit > 0 ? limit : 20;
    if (ftsAvailable) {
      final match = _sanitizeMatch(trimmed);
      if (match.isEmpty) return const [];
      return _db
          .select(
            "SELECT book_id, chapter, title, snippet(book_fts, 3, '<b>', '</b>', '…', 32) AS snippet "
            'FROM book_fts WHERE book_fts MATCH ? '
            'ORDER BY rank LIMIT ?',
            [match, maxRows],
          )
          .map(
            (r) => {
              'book_id': r['book_id'],
              'chapter': r['chapter'],
              'title': r['title'],
              'snippet': r['snippet'],
            },
          )
          .toList();
    }
    // Fallback: plain LIKE over the regular table. Escape LIKE wildcards so
    // user-typed '%' and '_' are matched literally, and fold both sides so
    // non-ASCII capitals match.
    final escaped = foldText(
      trimmed,
    ).replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
    final pattern = '%$escaped%';
    return _db
        .select(
          'SELECT book_id, chapter, title, content FROM book_fts '
          r"WHERE vellum_fold(content) LIKE ? ESCAPE '\' "
          r"OR vellum_fold(title) LIKE ? ESCAPE '\' "
          'ORDER BY book_id, chapter LIMIT ?',
          [pattern, pattern, maxRows],
        )
        .map(
          (r) => {
            'book_id': r['book_id'],
            'chapter': r['chapter'],
            'title': r['title'],
            'snippet': _makeSnippet(
              r['content'] as String,
              r['title'] as String,
              trimmed,
            ),
          },
        )
        .toList();
  }

  static String _makeSnippet(String content, String title, String query) {
    final needle = foldText(query);
    var idx = foldText(content).indexOf(needle);
    var haystack = content;
    if (idx < 0) {
      idx = foldText(title).indexOf(needle);
      haystack = title;
    }
    if (idx < 0) {
      return content.length <= 64 ? content : '${content.substring(0, 64)}…';
    }
    const context = 24;
    final start = idx - context < 0 ? 0 : idx - context;
    final end = idx + needle.length + context > haystack.length
        ? haystack.length
        : idx + needle.length + context;
    final prefix = start > 0 ? '…' : '';
    final suffix = end < haystack.length ? '…' : '';
    return '$prefix${haystack.substring(start, end)}$suffix';
  }
}

/// Identity of the source file a snapshot of FTS rows was extracted from.
///
/// Stored in `fts_index_state` beside the rows, so the skip decision cannot
/// outlive them. Path is part of the identity: a book re-imported elsewhere
/// must be re-indexed even when its mtime and size happen to match.
class FtsSource {
  const FtsSource({
    required this.path,
    required this.mtimeMs,
    required this.size,
  });

  /// Stats [path]; null when it does not name a regular file.
  static FtsSource? of(String path) {
    if (path.isEmpty) return null;
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      return FtsSource(
        path: path,
        mtimeMs: stat.modified.millisecondsSinceEpoch,
        size: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }

  final String path;
  final int mtimeMs;
  final int size;

  bool matches(FtsSource other) =>
      path == other.path && mtimeMs == other.mtimeMs && size == other.size;
}

/// FTS rows for one book together with the source file they came from.
class FtsIndexEntry {
  const FtsIndexEntry({required this.rows, this.source});

  final List<Map<String, Object>> rows;

  /// Null when there is no source file (PDF-only or manually supplied rows);
  /// such a book is never skipped by [Library.ftsSourceFor].
  final FtsSource? source;
}

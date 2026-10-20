/// Tests for importing a calibre library folder.
///
/// Mirrors /tmp/vellum/tests/test_calibre.py. The Dart port cannot
/// monkeypatch `_importRow`, so the per-row-failure test closes the target
/// library instead: every row fails, the import completes, and failures are
/// counted rather than thrown.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/import/calibre.dart';

const _calibreSchema = '''
CREATE TABLE books (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL DEFAULT '',
    sort TEXT NOT NULL DEFAULT '',
    timestamp TEXT,
    pubdate TEXT,
    path TEXT NOT NULL DEFAULT '',
    has_cover INTEGER NOT NULL DEFAULT 0,
    isbn TEXT NOT NULL DEFAULT '',
    uuid TEXT
);
CREATE TABLE authors (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT, link TEXT
);
CREATE TABLE books_authors_link (
    id INTEGER PRIMARY KEY, book INTEGER, author INTEGER
);
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE books_tags_link (
    id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER
);
CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE books_publishers_link (
    id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER
);
CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER);
CREATE TABLE books_ratings_link (
    id INTEGER PRIMARY KEY, book INTEGER, rating INTEGER
);
CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT NOT NULL);
CREATE TABLE books_languages_link (
    id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER, item_order INTEGER
);
CREATE TABLE identifiers (
    id INTEGER PRIMARY KEY, book INTEGER, type TEXT, value TEXT
);
CREATE TABLE data (
    id INTEGER PRIMARY KEY, book INTEGER, format TEXT,
    uncompressed_size INTEGER, name TEXT
);
''';

const _calibreRows = [
  "INSERT INTO books (id, title, sort, pubdate, path, has_cover, uuid)"
      " VALUES (1, 'A Book', 'Book, A', '2001-02-03 00:00:00+00:00',"
      " 'Jane Author/A Book (1)', 1, 'uuid-1')",
  "INSERT INTO authors (id, name) VALUES (1, 'Jane Author')",
  "INSERT INTO books_authors_link (book, author) VALUES (1, 1)",
  "INSERT INTO tags (id, name) VALUES (1, 'Fantasy')",
  "INSERT INTO tags (id, name) VALUES (2, 'Adventure')",
  "INSERT INTO books_tags_link (book, tag) VALUES (1, 1)",
  "INSERT INTO books_tags_link (book, tag) VALUES (1, 2)",
  "INSERT INTO publishers (id, name) VALUES (1, 'Acme Press')",
  "INSERT INTO books_publishers_link (book, publisher) VALUES (1, 1)",
  "INSERT INTO comments (book, text) VALUES"
      " (1, '<p>First <b>para</b>.</p><p>Second &amp; last.</p>')",
  "INSERT INTO ratings (id, rating) VALUES (1, 9)",
  "INSERT INTO books_ratings_link (book, rating) VALUES (1, 1)",
  "INSERT INTO languages (id, lang_code) VALUES (1, 'eng')",
  "INSERT INTO books_languages_link (book, lang_code, item_order)"
      " VALUES (1, 1, 1)",
  "INSERT INTO identifiers (book, type, value) VALUES"
      " (1, 'isbn', '9781234567890')",
  "INSERT INTO data (book, format, name) VALUES (1, 'EPUB', 'Book')",
  "INSERT INTO data (book, format, name) VALUES (1, 'PDF', 'Book')",
];

void main() {
  late Directory tmp;
  late Library library;
  late Directory calibreRoot;

  Directory createCalibreLibrary() {
    final root = Directory(p.join(tmp.path, 'Calibre Library'))
      ..createSync();
    final bookDir =
        Directory(p.join(root.path, 'Jane Author', 'A Book (1)'))
          ..createSync(recursive: true);
    File(p.join(bookDir.path, 'Book.epub')).writeAsBytesSync([0x65]);
    File(p.join(bookDir.path, 'Book.pdf')).writeAsBytesSync([0x70]);
    File(p.join(bookDir.path, 'cover.jpg')).writeAsBytesSync([0x6A]);

    final db = sqlite3.open(p.join(root.path, 'metadata.db'));
    db.execute(_calibreSchema);
    for (final stmt in _calibreRows) {
      db.execute(stmt);
    }
    db.dispose();
    return root;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-calibre-test-');
    library = Library(p.join(tmp.path, 'vellum.db'));
    calibreRoot = createCalibreLibrary();
  });

  tearDown(() {
    library.close();
    tmp.deleteSync(recursive: true);
  });

  test('isCalibreLibrary', () {
    expect(isCalibreLibrary(calibreRoot.path), isTrue);
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    expect(isCalibreLibrary(empty.path), isFalse);
  });

  test('importCalibreLibrary imports full metadata', () async {
    final progress = <(int, int)>[];
    final result = await importCalibreLibrary(library, calibreRoot.path,
        progress: (done, total) => progress.add((done, total)));
    expect(result.added, 1);
    expect(result.skipped, 0);
    expect(result.failed, 0);
    expect(progress, [(1, 1)]);

    final books = library.allBooks(includeHidden: true);
    expect(books, hasLength(1));
    final book = books.single;
    expect(book.title, 'A Book');
    expect(book.authors, ['Jane Author']);
    expect(book.isbn, '9781234567890');
    expect(book.publisher, 'Acme Press');
    expect(book.pubdate, '2001');
    expect(book.language, 'eng');
    expect(book.rating, closeTo(4.5, 1e-9));
    expect(book.formats, ['epub', 'pdf']);
    final bookDir = p.join(calibreRoot.path, 'Jane Author', 'A Book (1)');
    expect(book.path, p.join(bookDir, 'Book.epub'));
    expect(book.coverPath, p.join(bookDir, 'cover.jpg'));
    expect(book.sourceId, 'calibre:uuid-1');
    expect(book.hidden, isFalse);
    expect(book.description, contains('First para.'));
    expect(book.description, contains('Second & last.'));
  });

  test('reimport skips existing books', () async {
    expect((await importCalibreLibrary(library, calibreRoot.path)).added, 1);
    final second = await importCalibreLibrary(library, calibreRoot.path);
    expect(second.added, 0);
    expect(second.skipped, 1);
    expect(library.allBooks(includeHidden: true), hasLength(1));
  });

  test('reimport skips hidden book and keeps it hidden', () async {
    await importCalibreLibrary(library, calibreRoot.path);
    final book = library.allBooks(includeHidden: true).single;
    library.setHidden(book.id!, true);
    final second = await importCalibreLibrary(library, calibreRoot.path);
    expect(second.skipped, 1);
    expect(library.getBook(book.id!)!.hidden, isTrue);
  });

  test('missing metadata.db throws', () async {
    expect(() => importCalibreLibrary(library, tmp.path),
        throwsA(isA<ArgumentError>()));
  });

  test('format path outside library is ignored', () async {
    final db = sqlite3.open(p.join(calibreRoot.path, 'metadata.db'));
    db.execute("UPDATE books SET path = '../escape'");
    db.dispose();

    final result = await importCalibreLibrary(library, calibreRoot.path);
    expect(result.added, 1);
    final book = library.allBooks(includeHidden: true).single;
    expect(book.path, '');
    expect(book.formats, isEmpty);
  });

  test('row failure is counted, not fatal', () async {
    // A disposed library makes every per-row import throw; the import must
    // still complete and report the failures.
    library.close();
    final result = await importCalibreLibrary(library, calibreRoot.path);
    expect(result.failed, 1);
    expect(result.added, 0);
    expect(result.firstError, isNotEmpty);
    // Replace the closed library so tearDown does not dispose it twice.
    library = Library(p.join(tmp.path, 'vellum2.db'));
  });

  test('broken optional table does not fail the book', () async {
    final db = sqlite3.open(p.join(calibreRoot.path, 'metadata.db'));
    db.execute('DROP TABLE books_tags_link');
    db.execute('CREATE TABLE books_tags_link ('
        ' id INTEGER PRIMARY KEY, book INTEGER, tag_id INTEGER)');
    db.dispose();

    final result = await importCalibreLibrary(library, calibreRoot.path);
    expect(result.added, 1);
    expect(result.failed, 0);
    expect(library.allBooks(includeHidden: true).single.tags, isEmpty);
  });

  test('import does not modify the calibre database', () async {
    final dbFile = File(p.join(calibreRoot.path, 'metadata.db'));
    final before = dbFile.readAsBytesSync();

    await importCalibreLibrary(library, calibreRoot.path);

    expect(dbFile.readAsBytesSync(), before);
  });
}

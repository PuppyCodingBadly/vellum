import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';

void main() {
  group('Library basic CRUD', () {
    test(':memory: round trip incl. author order and tag alpha sort', () {
      final lib = Library(':memory:');
      final book = Book(
        title: 'Dune',
        authors: ['Frank Herbert', 'Someone Else'],
        tags: ['scifi', 'classic'],
        formats: ['epub', 'pdf'],
        path: '/books/dune.epub',
        rating: 4.5,
      );
      final id = lib.addBook(book);
      expect(id, greaterThan(0));
      expect(book.id, id);
      expect(book.added, isNotEmpty);

      final loaded = lib.getBook(id)!;
      expect(loaded.title, 'Dune');
      expect(loaded.authors, ['Frank Herbert', 'Someone Else']);
      expect(loaded.tags, ['classic', 'scifi']); // alphabetical
      expect(loaded.formats, ['epub', 'pdf']); // alphabetical
      expect(loaded.rating, 4.5);
      expect(loaded.hidden, isFalse);
      expect(loaded.sourceId, '');
      lib.close();
    });

    test('getBook unknown id returns null', () {
      final lib = Library(':memory:');
      expect(lib.getBook(9999), isNull);
      lib.close();
    });

    test('updateBook null id throws ArgumentError', () {
      final lib = Library(':memory:');
      expect(() => lib.updateBook(Book(title: 'x')), throwsArgumentError);
      lib.close();
    });

    test('updateBook unknown id throws StateError', () {
      final lib = Library(':memory:');
      expect(() => lib.updateBook(Book(id: 4242, title: 'x')),
          throwsStateError);
      lib.close();
    });

    test('updateBook replaces links', () {
      final lib = Library(':memory:');
      final id = lib.addBook(Book(
          title: 'T', authors: ['A1', 'A2'], tags: ['t1'], formats: ['epub']));
      final book = lib.getBook(id)!
        ..authors = ['B1']
        ..tags = ['t2', 't3']
        ..formats = ['pdf'];
      lib.updateBook(book);
      final loaded = lib.getBook(id)!;
      expect(loaded.authors, ['B1']);
      expect(loaded.tags, ['t2', 't3']);
      expect(loaded.formats, ['pdf']);
      lib.close();
    });

    test('deleteBook cascades children', () {
      final lib = Library(':memory:');
      final id = lib.addBook(
          Book(title: 'T', authors: ['A'], tags: ['x'], formats: ['epub']));
      lib.addHighlight(id, 'pos', 'yellow', 'hello');
      lib.setReadingPosition(id, 'loc');
      lib.deleteBook(id);
      expect(lib.getBook(id), isNull);
      expect(lib.listHighlights(id), isEmpty);
      expect(lib.getReadingPosition(id), isNull);
      lib.close();
    });

    test('setHidden unknown id throws StateError', () {
      final lib = Library(':memory:');
      expect(() => lib.setHidden(9999, true), throwsStateError);
      lib.close();
    });

    test('hidden excluded by default, included with includeHidden', () {
      final lib = Library(':memory:');
      final id = lib.addBook(Book(title: 'Secret'));
      lib.setHidden(id, true);
      expect(lib.allBooks(), isEmpty);
      expect(lib.allBooks(includeHidden: true), hasLength(1));
      expect(lib.search('secret'), isEmpty);
      expect(lib.search('secret', includeHidden: true), hasLength(1));
      lib.close();
    });

    test('findBySourceId: empty returns null, match returns book', () {
      final lib = Library(':memory:');
      final id =
          lib.addBook(Book(title: 'Cal', sourceId: 'calibre:uuid-1'));
      expect(lib.findBySourceId(''), isNull);
      expect(lib.findBySourceId('missing'), isNull);
      expect(lib.findBySourceId('calibre:uuid-1')!.id, id);
      lib.close();
    });

    test('baseDir: cwd for :memory:, parent of db file otherwise', () {
      final mem = Library(':memory:');
      expect(mem.baseDir, Directory.current.path);
      mem.close();
      final tmp = Directory.systemTemp.createTempSync('vellum-dbtest');
      final path = '${tmp.path}/sub/library.db';
      File(path).parent.createSync(recursive: true);
      final lib = Library(path);
      expect(lib.baseDir, File('${tmp.path}/sub').absolute.path);
      lib.close();
      tmp.deleteSync(recursive: true);
    });

    test('close on a file-backed library is a no-op', () {
      final tmp = Directory.systemTemp.createTempSync('vellum-close');
      final lib = Library('${tmp.path}/library.db');
      lib.addBook(Book(title: 'T'));
      lib.close();
      // Persistent connection stays usable (Python contract: close only
      // matters for :memory:).
      expect(lib.allBooks(), hasLength(1));
      tmp.deleteSync(recursive: true);
    });
  });

  group('Library search', () {
    test('empty/whitespace query returns all books', () {
      final lib = Library(':memory:');
      lib.addBook(Book(title: 'Alpha'));
      lib.addBook(Book(title: 'Beta'));
      expect(lib.search(''), hasLength(2));
      expect(lib.search('   '), hasLength(2));
      lib.close();
    });

    test('AND tokens, case-insensitive, across title/author/tag/isbn', () {
      final lib = Library(':memory:');
      lib.addBook(Book(
          title: 'The Left Hand of Darkness',
          authors: ['Ursula K. Le Guin'],
          tags: ['scifi'],
          isbn: '9780441478125'));
      lib.addBook(Book(title: 'Dune', authors: ['Frank Herbert']));
      // Matches via title + author.
      expect(lib.search('left le guin'), hasLength(1));
      // Matches via tag.
      expect(lib.search('SCIFI'), hasLength(1));
      // Matches via isbn.
      expect(lib.search('0441478125'), hasLength(1));
      // AND semantics: one token matches only the other book.
      expect(lib.search('darkness dune'), isEmpty);
      // Case-insensitive.
      expect(lib.search('LEFT HAND'), hasLength(1));
      lib.close();
    });
  });

  group('deleteBooksWithoutFiles', () {
    test('deletes only matching titles without path or formats', () {
      final lib = Library(':memory:');
      final doomed = lib.addBook(Book(title: 'Dune'));
      lib.addBook(Book(title: 'Dune', path: '/x/dune.epub'));
      lib.addBook(Book(title: 'Dune', formats: ['epub']));
      lib.addBook(Book(title: 'Other'));
      final hidden = lib.addBook(Book(title: 'Dune', hidden: true));
      final deleted = lib.deleteBooksWithoutFiles({'Dune'});
      expect(deleted, 2); // hidden ones are deleted too
      expect(lib.getBook(doomed), isNull);
      expect(lib.getBook(hidden), isNull);
      expect(lib.allBooks(includeHidden: true), hasLength(3));
      expect(lib.deleteBooksWithoutFiles({}), 0);
      lib.close();
    });
  });

  group('highlights and reading positions', () {
    test('highlight add/list/delete', () {
      final lib = Library(':memory:');
      final id = lib.addBook(Book(title: 'T'));
      final h1 = lib.addHighlight(id, 'epubcfi(/6/4)', 'yellow', 'one');
      final h2 = lib.addHighlight(id, 'epubcfi(/6/8)', 'pink', 'two');
      final list = lib.listHighlights(id);
      expect(list, hasLength(2));
      expect(list[0]['id'], h1);
      expect(list[1]['id'], h2);
      expect(list[0]['position'], 'epubcfi(/6/4)');
      expect(list[0]['color'], 'yellow');
      expect(list[0]['text'], 'one');
      expect(list[0]['created'], isNotNull);
      lib.deleteHighlight(h1);
      expect(lib.listHighlights(id), hasLength(1));
      lib.close();
    });

    test('reading position set/get/replace', () {
      final lib = Library(':memory:');
      final id = lib.addBook(Book(title: 'T'));
      expect(lib.getReadingPosition(id), isNull);
      lib.setReadingPosition(id, 'loc-1');
      expect(lib.getReadingPosition(id), 'loc-1');
      lib.setReadingPosition(id, 'loc-2');
      expect(lib.getReadingPosition(id), 'loc-2');
      lib.close();
    });
  });

  group('migration', () {
    test('opens schema without hidden/source_id and works', () {
      final tmp = Directory.systemTemp.createTempSync('vellum-migrate');
      final path = '${tmp.path}/library.db';
      // Build an old-schema database directly.
      final raw = sqlite3.open(path);
      raw.execute('''
CREATE TABLE books (
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
    added TEXT NOT NULL DEFAULT ''
);
''');
      raw.execute("INSERT INTO books (title) VALUES ('Old Book')");
      raw.dispose();

      final lib = Library(path);
      final books = lib.allBooks();
      expect(books, hasLength(1));
      expect(books.first.title, 'Old Book');
      expect(books.first.hidden, isFalse);
      expect(books.first.sourceId, '');
      // New columns usable after migration.
      lib.setHidden(books.first.id!, true);
      expect(lib.allBooks(), isEmpty);
      lib.close();
      tmp.deleteSync(recursive: true);
    });
  });

  group('shelves', () {
    test('CRUD, membership, hidden filtering, cascade', () {
      final lib = Library(':memory:');
      final shelf = lib.createShelf('Favorites');
      expect(shelf, greaterThan(0));
      final b1 = lib.addBook(Book(title: 'Beta'));
      final b2 = lib.addBook(Book(title: 'Alpha'));
      final b3 = lib.addBook(Book(title: 'Hidden Book', hidden: true));
      lib.addBookToShelf(shelf, b1);
      lib.addBookToShelf(shelf, b2);
      lib.addBookToShelf(shelf, b2); // duplicate ignored
      lib.addBookToShelf(shelf, b3);

      var shelves = lib.listShelves();
      expect(shelves, hasLength(1));
      expect(shelves.first['name'], 'Favorites');
      expect(shelves.first['book_count'], 3);

      lib.renameShelf(shelf, 'Best');
      expect(lib.listShelves().first['name'], 'Best');

      // Ordered by title; hidden excluded by default.
      expect(lib.shelfBooks(shelf).map((b) => b.title), ['Alpha', 'Beta']);
      expect(lib.shelfBooks(shelf, includeHidden: true), hasLength(3));

      expect(lib.shelvesForBook(b2), [shelf]);
      lib.removeBookFromShelf(shelf, b2);
      expect(lib.shelfBooks(shelf).map((b) => b.title), ['Beta'],
          reason: 'Alpha removed; hidden book excluded by default');
      expect(lib.shelvesForBook(b2), isEmpty);

      // Deleting a book cascades out of shelf_books; Beta (b1) remains.
      lib.deleteBook(b3);
      expect(lib.listShelves().first['book_count'], 1);

      lib.deleteShelf(shelf);
      expect(lib.listShelves(), isEmpty);
      lib.close();
    });

    test('deleting a shelf cascades membership', () {
      final lib = Library(':memory:');
      final shelf = lib.createShelf('S');
      final b = lib.addBook(Book(title: 'T'));
      lib.addBookToShelf(shelf, b);
      lib.deleteShelf(shelf);
      expect(lib.shelvesForBook(b), isEmpty);
      expect(lib.getBook(b), isNotNull); // book itself survives
      lib.close();
    });
  });

  group('reading stats', () {
    test('per-book and library aggregation', () {
      final lib = Library(':memory:');
      final b1 = lib.addBook(Book(title: 'A'));
      final b2 = lib.addBook(Book(title: 'B'));
      lib.addReadingSession(b1, '2026-10-01T10:00:00Z', 300, 'loc1');
      lib.addReadingSession(b1, '2026-10-02T10:00:00Z', 120, 'loc2');
      lib.addReadingSession(b2, '2026-10-03T10:00:00Z', 60, 'loc3');

      final bookStats = lib.statsForBook(b1);
      expect(bookStats['totalSeconds'], 420);
      expect(bookStats['sessions'], 2);
      expect(bookStats['lastRead'], '2026-10-02T10:00:00Z');

      final empty = lib.statsForBook(9999);
      expect(empty['totalSeconds'], 0);
      expect(empty['sessions'], 0);
      expect(empty['lastRead'], isNull);

      final all = lib.libraryStats();
      expect(all['totalSeconds'], 480);
      expect(all['booksRead'], 2);
      expect(all['sessions'], 3);
      lib.close();
    });

    test('recentReadingSessions returns newest first with limit', () {
      final lib = Library(':memory:');
      final b1 = lib.addBook(Book(title: 'A'));
      final b2 = lib.addBook(Book(title: 'B'));
      lib.addReadingSession(b1, '2026-10-01T10:00:00Z', 300, 'loc1');
      lib.addReadingSession(b2, '2026-10-02T10:00:00Z', 120, 'loc2');
      lib.addReadingSession(b1, '2026-10-03T10:00:00Z', 60, 'loc3');

      final all = lib.recentReadingSessions(10);
      expect(all, hasLength(3));
      expect(all[0]['end_locator'], 'loc3');
      expect(all[1]['end_locator'], 'loc2');
      expect(all[2]['end_locator'], 'loc1');
      expect(all[0]['book_id'], b1);
      expect(all[0]['duration_seconds'], 60);
      expect(all[0]['started'], '2026-10-03T10:00:00Z');
      expect(all[0]['id'], greaterThan(all[1]['id'] as int));

      expect(lib.recentReadingSessions(2), hasLength(2));
      lib.close();
    });

    test('sessions cascade with book deletion', () {
      final lib = Library(':memory:');
      final b = lib.addBook(Book(title: 'A'));
      lib.addReadingSession(b, '2026-10-01T10:00:00Z', 300, 'loc1');
      lib.deleteBook(b);
      expect(lib.libraryStats()['sessions'], 0);
      lib.close();
    });
  });

  group('full-text search', () {
    test('index and search with snippet', () {
      final lib = Library(':memory:');
      final b = lib.addBook(Book(title: 'Novel'));
      lib.replaceBookFts(b, [
        {'chapter': 0, 'title': 'Start', 'content': 'It was a dark night.'},
        {
          'chapter': 1,
          'title': 'Middle',
          'content':
              'The quick brown fox jumps over the lazy dog near the riverbank.'
        },
      ]);
      if (lib.ftsAvailable) {
        final hits = lib.searchBookContent('brown fox');
        expect(hits, hasLength(1));
        expect(hits.first['book_id'], b);
        expect(hits.first['chapter'], 1);
        expect(hits.first['title'], 'Middle');
        expect(hits.first['snippet'] as String, contains('<b>'));

        // AND semantics: no single row matches both tokens.
        expect(lib.searchBookContent('brown darkness'), isEmpty);

        // Quotes and weird characters are sanitized away.
        expect(lib.searchBookContent('"brown" OR "darkness"'), isEmpty);
      } else {
        final hits = lib.searchBookContent('brown fox');
        expect(hits, hasLength(1));
        expect(hits.first['chapter'], 1);
        expect(hits.first['snippet'] as String, contains('brown fox'));
      }
      lib.close();
    });

    test('replaceBookFts replaces existing rows', () {
      final lib = Library(':memory:');
      final b = lib.addBook(Book(title: 'Novel'));
      lib.replaceBookFts(b, [
        {'chapter': 0, 'title': 'Old', 'content': 'xyzzy old content'}
      ]);
      lib.replaceBookFts(b, [
        {'chapter': 0, 'title': 'New', 'content': 'plugh new content'}
      ]);
      expect(lib.searchBookContent('xyzzy'), isEmpty);
      expect(lib.searchBookContent('plugh'), hasLength(1));
      lib.close();
    });

    test('deleteBook removes rows from book_fts', () {
      final lib = Library(':memory:');
      final b = lib.addBook(Book(title: 'Novel'));
      lib.replaceBookFts(b, [
        {'chapter': 0, 'title': 'Ch', 'content': 'zorkmid treasure'}
      ]);
      expect(lib.searchBookContent('zorkmid'), hasLength(1));
      lib.deleteBook(b);
      expect(lib.searchBookContent('zorkmid'), isEmpty);
      lib.close();
    });

    test('fallback LIKE path when book_fts is a plain table', () {
      final tmp = Directory.systemTemp.createTempSync('vellum-fts');
      final path = '${tmp.path}/library.db';
      // Pre-create a plain (non-FTS) book_fts table.
      final raw = sqlite3.open(path);
      raw.execute(
          'CREATE TABLE book_fts (book_id INTEGER, chapter INTEGER, title TEXT, content TEXT)');
      raw.dispose();

      final lib = Library(path);
      expect(lib.ftsAvailable, isFalse);
      final b = lib.addBook(Book(title: 'Novel'));
      lib.replaceBookFts(b, [
        {
          'chapter': 2,
          'title': 'Ch',
          'content':
              'Some long text with the magic needle phrase deep inside it all.'
        }
      ]);
      final hits = lib.searchBookContent('needle phrase');
      expect(hits, hasLength(1));
      expect(hits.first['book_id'], b);
      expect(hits.first['chapter'], 2);
      final snippet = hits.first['snippet'] as String;
      expect(snippet, contains('needle phrase'));
      expect(snippet, contains('…'));
      expect(lib.searchBookContent('absent'), isEmpty);

      // LIKE wildcards in the query are matched literally.
      lib.replaceBookFts(b, [
        {
          'chapter': 3,
          'title': 'Pct',
          'content': 'Discount is 100% real_thing today.'
        }
      ]);
      expect(lib.searchBookContent('100%'), hasLength(1));
      expect(lib.searchBookContent('real_thing'), hasLength(1));
      expect(lib.searchBookContent('%%%'), isEmpty);
      lib.close();
      tmp.deleteSync(recursive: true);
    });
  });
}

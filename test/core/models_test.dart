import 'package:test/test.dart';
import 'package:vellum/core/models.dart';

/// A fully populated book fixture; every field set to a non-default value.
Book baseBook() => Book(
      id: 7,
      title: 'The Title',
      authors: ['Alice', 'Bob'],
      sort: 'Title, The',
      isbn: '9780123456789',
      publisher: 'Publisher',
      pubdate: '2020-01-01',
      language: 'en',
      description: 'A description',
      tags: ['fiction', 'classic'],
      formats: ['EPUB', 'PDF'],
      coverPath: '/covers/7.jpg',
      path: '/books/7',
      rating: 4.5,
      added: '2021-06-01T00:00:00',
      hidden: true,
      sourceId: 'src-1',
    );

void main() {
  group('Author', () {
    test('default sort is empty', () {
      expect(const Author('Jane Doe').sort, '');
    });

    test('identical fields are equal', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane'),
          const Author('Jane Doe', sort: 'Doe, Jane'));
    });

    test('differing name is unequal', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane'),
          isNot(const Author('John Doe', sort: 'Doe, Jane')));
    });

    test('differing sort is unequal', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane'),
          isNot(const Author('Jane Doe', sort: 'Jane Doe')));
    });

    test('not equal to other types', () {
      // ignore: unrelated_type_equality_checks
      expect(const Author('Jane Doe'), isNot('Jane Doe'));
    });

    test('equal authors have equal hashCodes', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane').hashCode,
          const Author('Jane Doe', sort: 'Doe, Jane').hashCode);
    });

    test('copyWith replaces name and keeps sort', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane').copyWith(name: 'Janet'),
          const Author('Janet', sort: 'Doe, Jane'));
    });

    test('copyWith replaces sort and keeps name', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane').copyWith(sort: 'Doe, J'),
          const Author('Jane Doe', sort: 'Doe, J'));
    });

    test('copyWith with no arguments returns an equal author', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane').copyWith(),
          const Author('Jane Doe', sort: 'Doe, Jane'));
    });

    test('toString contains name and sort', () {
      expect(const Author('Jane Doe', sort: 'Doe, Jane').toString(),
          'Author(name: Jane Doe, sort: Doe, Jane)');
    });
  });

  group('Book defaults', () {
    test('all fields default to null/empty/zero', () {
      final b = Book();
      expect(b.id, isNull);
      expect(b.title, '');
      expect(b.authors, isEmpty);
      expect(b.sort, '');
      expect(b.isbn, '');
      expect(b.publisher, '');
      expect(b.pubdate, '');
      expect(b.language, '');
      expect(b.description, '');
      expect(b.tags, isEmpty);
      expect(b.formats, isEmpty);
      expect(b.coverPath, '');
      expect(b.path, '');
      expect(b.rating, 0.0);
      expect(b.added, '');
      expect(b.hidden, isFalse);
      expect(b.sourceId, '');
    });

    test('omitted list fields get independent mutable lists', () {
      final a = Book();
      final b = Book();
      a.authors.add('Alice');
      expect(b.authors, isEmpty);
    });
  });

  group('Book equality', () {
    test('identical fields are equal', () {
      expect(baseBook(), baseBook());
    });

    test('list fields compare by contents, not identity', () {
      final a = baseBook();
      final b = baseBook();
      expect(identical(a.authors, b.authors), isFalse);
      expect(a, b);
    });

    test('not equal to other types', () {
      // ignore: unrelated_type_equality_checks
      expect(baseBook(), isNot('not a book'));
    });

    final differing = <String, Book Function()>{
      'id': () => baseBook()..id = 8,
      'title': () => baseBook()..title = 'Other',
      'authors': () => baseBook()..authors = ['Carol'],
      'sort': () => baseBook()..sort = 'Other',
      'isbn': () => baseBook()..isbn = '0123456789',
      'publisher': () => baseBook()..publisher = 'Other',
      'pubdate': () => baseBook()..pubdate = '1999-12-31',
      'language': () => baseBook()..language = 'fr',
      'description': () => baseBook()..description = 'Other',
      'tags': () => baseBook()..tags = ['other'],
      'formats': () => baseBook()..formats = ['MOBI'],
      'coverPath': () => baseBook()..coverPath = '/other.jpg',
      'path': () => baseBook()..path = '/other',
      'rating': () => baseBook()..rating = 1.0,
      'added': () => baseBook()..added = '2022-01-01',
      'hidden': () => baseBook()..hidden = false,
      'sourceId': () => baseBook()..sourceId = 'src-2',
    };

    for (final entry in differing.entries) {
      test('differing ${entry.key} is unequal', () {
        expect(baseBook(), isNot(entry.value()));
      });
    }

    test('list field order matters', () {
      expect(baseBook(),
          isNot(baseBook()..authors = ['Bob', 'Alice']));
    });

    test('equal books have equal hashCodes', () {
      expect(baseBook().hashCode, baseBook().hashCode);
    });
  });

  group('Book copyWith', () {
    test('no arguments returns an equal book', () {
      expect(baseBook().copyWith(), baseBook());
    });

    test('id replaces id', () {
      expect(baseBook().copyWith(id: () => 42), baseBook()..id = 42);
    });

    test('id can clear id to null', () {
      expect(baseBook().copyWith(id: () => null), baseBook()..id = null);
    });

    test('title replaces title only', () {
      expect(baseBook().copyWith(title: 'New'), baseBook()..title = 'New');
    });

    test('authors replaces authors only', () {
      expect(baseBook().copyWith(authors: ['Carol']),
          baseBook()..authors = ['Carol']);
    });

    test('sort replaces sort only', () {
      expect(baseBook().copyWith(sort: 'New'), baseBook()..sort = 'New');
    });

    test('isbn replaces isbn only', () {
      expect(baseBook().copyWith(isbn: '111'), baseBook()..isbn = '111');
    });

    test('publisher replaces publisher only', () {
      expect(baseBook().copyWith(publisher: 'New'),
          baseBook()..publisher = 'New');
    });

    test('pubdate replaces pubdate only', () {
      expect(baseBook().copyWith(pubdate: '2000-01-01'),
          baseBook()..pubdate = '2000-01-01');
    });

    test('language replaces language only', () {
      expect(baseBook().copyWith(language: 'de'),
          baseBook()..language = 'de');
    });

    test('description replaces description only', () {
      expect(baseBook().copyWith(description: 'New'),
          baseBook()..description = 'New');
    });

    test('tags replaces tags only', () {
      expect(baseBook().copyWith(tags: ['new']), baseBook()..tags = ['new']);
    });

    test('formats replaces formats only', () {
      expect(baseBook().copyWith(formats: ['MOBI']),
          baseBook()..formats = ['MOBI']);
    });

    test('coverPath replaces coverPath only', () {
      expect(baseBook().copyWith(coverPath: '/new.jpg'),
          baseBook()..coverPath = '/new.jpg');
    });

    test('path replaces path only', () {
      expect(baseBook().copyWith(path: '/new'), baseBook()..path = '/new');
    });

    test('rating replaces rating only', () {
      expect(baseBook().copyWith(rating: 2.5), baseBook()..rating = 2.5);
    });

    test('added replaces added only', () {
      expect(baseBook().copyWith(added: '2030-01-01'),
          baseBook()..added = '2030-01-01');
    });

    test('hidden replaces hidden only', () {
      expect(baseBook().copyWith(hidden: false), baseBook()..hidden = false);
    });

    test('sourceId replaces sourceId only', () {
      expect(baseBook().copyWith(sourceId: 'src-9'),
          baseBook()..sourceId = 'src-9');
    });

    test('list fields are copied, not shared', () {
      final b = baseBook();
      final c = b.copyWith();
      b.authors.add('Eve');
      b.tags.add('new');
      b.formats.add('MOBI');
      expect(c.authors, ['Alice', 'Bob']);
      expect(c.tags, ['fiction', 'classic']);
      expect(c.formats, ['EPUB', 'PDF']);
    });
  });

  group('Book toString', () {
    test('contains all field values', () {
      final s = baseBook().toString();
      for (final fragment in [
        'id: 7',
        'title: The Title',
        'authors: [Alice, Bob]',
        'sort: Title, The',
        'isbn: 9780123456789',
        'publisher: Publisher',
        'pubdate: 2020-01-01',
        'language: en',
        'description: A description',
        'tags: [fiction, classic]',
        'formats: [EPUB, PDF]',
        'coverPath: /covers/7.jpg',
        'path: /books/7',
        'rating: 4.5',
        'added: 2021-06-01T00:00:00',
        'hidden: true',
        'sourceId: src-1',
      ]) {
        expect(s, contains(fragment), reason: 'missing "$fragment"');
      }
    });
  });
}

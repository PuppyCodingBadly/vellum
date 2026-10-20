import 'package:test/test.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/core/sorting.dart';

Book b(String title,
        {List<String>? authors,
        double rating = 0.0,
        String added = ''}) =>
    Book(title: title, authors: authors ?? [], rating: rating, added: added);

void main() {
  test('SORT_OPTIONS and SORT_KEYS', () {
    expect(SORT_OPTIONS, [
      ('title', 'Title'),
      ('author', 'Author'),
      ('rating', 'Rating'),
      ('added', 'Recently added'),
    ]);
    expect(SORT_KEYS, ['title', 'author', 'rating', 'added']);
  });

  test('title sort is case-insensitive; empty title is Untitled', () {
    final books = [b('banana'), b(''), b('Apple')];
    final sorted = sortBooks(books);
    expect(sorted.map((x) => x.title), ['Apple', 'banana', '']);
  });

  test('author sort: joined authors, empty sorts last (￿)', () {
    final books = [
      b('No Author Z'),
      b('B', authors: ['Zelda']),
      b('A', authors: ['Amy', 'Bob']),
      b('No Author A'),
    ];
    final sorted = sortBooks(books, key: 'author');
    expect(
        sorted.map((x) => x.title), ['A', 'B', 'No Author A', 'No Author Z']);
  });

  test('author ties break by title', () {
    final books = [
      b('Zulu', authors: ['amy']),
      b('Alpha', authors: ['Amy']),
    ];
    final sorted = sortBooks(books, key: 'author');
    expect(sorted.map((x) => x.title), ['Alpha', 'Zulu']);
  });

  test('rating sort descending, tie by title', () {
    final books = [
      b('Mid', rating: 3.0),
      b('High', rating: 5.0),
      b('Also High', rating: 5.0),
      b('Low', rating: 1.0),
    ];
    final sorted = sortBooks(books, key: 'rating');
    expect(sorted.map((x) => x.title),
        ['Also High', 'High', 'Mid', 'Low']);
  });

  test('added sort: dated newest first, undated last by title', () {
    final books = [
      b('Undated B'),
      b('Old', added: '2020-01-01T00:00:00Z'),
      b('New', added: '2026-01-01T00:00:00Z'),
      b('Undated A'),
    ];
    final sorted = sortBooks(books, key: 'added');
    expect(sorted.map((x) => x.title),
        ['New', 'Old', 'Undated A', 'Undated B']);
  });

  test('unknown key sorts by title', () {
    final books = [b('b'), b('a')];
    expect(sortBooks(books, key: 'nope').map((x) => x.title), ['a', 'b']);
  });

  test('returns a new list, input unmodified', () {
    final books = [b('b'), b('a')];
    final sorted = sortBooks(books);
    expect(books.map((x) => x.title), ['b', 'a']);
    expect(identical(sorted, books), isFalse);
  });
}

/// Library sorting modes.
///
/// Ports `vellum/core/sorting.py`.
library;

// Mirrors the Python constants (sorting.py) verbatim.
// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'models.dart';

/// (key, label) pairs for the sort dropdown.
const List<(String, String)> SORT_OPTIONS = [
  ('title', 'Title'),
  ('author', 'Author'),
  ('rating', 'Rating'),
  ('added', 'Recently added'),
];

/// Valid sort keys.
final List<String> SORT_KEYS = [for (final (k, _) in SORT_OPTIONS) k];

String _titleKey(Book b) =>
    (b.title.isEmpty ? 'Untitled' : b.title).toLowerCase();

String _authorKey(Book b) =>
    (b.authors.isEmpty ? '￿' : b.authors.join(', ')).toLowerCase();

/// Returns a new, stably-sorted list of [books] according to [key].
///
/// Unknown keys sort by title.
List<Book> sortBooks(List<Book> books, {String key = 'title'}) {
  final result = List<Book>.of(books);
  switch (key) {
    case 'author':
      result.sort((a, b) {
        var c = _authorKey(a).compareTo(_authorKey(b));
        if (c != 0) return c;
        return _titleKey(a).compareTo(_titleKey(b));
      });
    case 'rating':
      result.sort((a, b) {
        var c = b.rating.compareTo(a.rating);
        if (c != 0) return c;
        return _titleKey(a).compareTo(_titleKey(b));
      });
    case 'added':
      final dated =
          result.where((b) => b.added.isNotEmpty).toList();
      final undated = result.where((b) => b.added.isEmpty).toList();
      dated.sort((a, b) {
        var c = b.added.compareTo(a.added);
        if (c != 0) return c;
        return _titleKey(a).compareTo(_titleKey(b));
      });
      undated.sort((a, b) => _titleKey(a).compareTo(_titleKey(b)));
      return [...dated, ...undated];
    default:
      result.sort((a, b) => _titleKey(a).compareTo(_titleKey(b)));
  }
  return result;
}

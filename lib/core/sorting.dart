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

/// Partial Python `str.casefold()`: handles the cases where casefold differs
/// from a plain lowercase mapping — 'ß' (→ 'ss') and final sigma 'ς' (→ 'σ').
String _casefold(String s) =>
    s.replaceAll('ß', 'ss').replaceAll('ς', 'σ').toLowerCase();

String _titleKey(Book b) =>
    _casefold(b.title.isEmpty ? 'Untitled' : b.title);

String _authorKey(Book b) {
  final joined = b.authors.join(', ');
  return _casefold(joined.isEmpty ? '￿' : joined);
}

/// Returns a new, stably-sorted list of [books] according to [key].
///
/// Unknown keys sort by title.
List<Book> sortBooks(List<Book> books, {String key = 'title'}) {
  // Decorate-sort-undecorate: List.sort is unstable, so carry the original
  // index as the final tiebreak to guarantee stability.
  final indexed = [for (var i = 0; i < books.length; i++) (i, books[i])];
  int stableCompare((int, Book) x, (int, Book) y, int Function(Book, Book) cmp) {
    final c = cmp(x.$2, y.$2);
    return c != 0 ? c : x.$1.compareTo(y.$1);
  }

  int byTitle(Book a, Book b) => _titleKey(a).compareTo(_titleKey(b));

  switch (key) {
    case 'author':
      indexed.sort((x, y) => stableCompare(x, y, (a, b) {
            var c = _authorKey(a).compareTo(_authorKey(b));
            if (c != 0) return c;
            return byTitle(a, b);
          }));
    case 'rating':
      indexed.sort((x, y) => stableCompare(x, y, (a, b) {
            var c = b.rating.compareTo(a.rating);
            if (c != 0) return c;
            return byTitle(a, b);
          }));
    case 'added':
      final dated = indexed.where((e) => e.$2.added.isNotEmpty).toList();
      final undated = indexed.where((e) => e.$2.added.isEmpty).toList();
      dated.sort((x, y) => stableCompare(x, y, (a, b) {
            var c = b.added.compareTo(a.added);
            if (c != 0) return c;
            // (added, title_key) REVERSED: title tie-breaks descending too.
            return byTitle(b, a);
          }));
      undated.sort((x, y) => stableCompare(x, y, byTitle));
      return [for (final e in [...dated, ...undated]) e.$2];
    default:
      indexed.sort((x, y) => stableCompare(x, y, byTitle));
  }
  return [for (final e in indexed) e.$2];
}

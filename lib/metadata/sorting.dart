/// Sorting for metadata search results.
library;

import 'metadata.dart';

const List<(String, String)> resultSortOptions = [
  ('relevance', 'Relevance'),
  ('title', 'Title'),
  ('author', 'Author'),
  ('rating', 'Rating'),
  ('pubdate', 'Newest'),
];

// ignore: non_constant_identifier_names
final List<String> RESULT_SORT_KEYS = [
  for (final (key, _) in resultSortOptions) key
];

String _title(Metadata meta) =>
    (meta.title.isEmpty ? 'Untitled' : meta.title).toLowerCase();

String _author(Metadata meta) =>
    (meta.authors.isEmpty ? '￿' : meta.authors.join(', ')).toLowerCase();

List<Metadata> sortMetadata(List<Metadata> results, [String key = 'relevance']) {
  final items = List.of(results);
  if (key == 'relevance' || items.isEmpty) return items;

  final merged = items.where((m) => m.sourceId == 'merged').toList();
  var rest = items.where((m) => m.sourceId != 'merged').toList();
  int byTitle(Metadata a, Metadata b) => _title(a).compareTo(_title(b));
  switch (key) {
    case 'title':
      rest.sort(byTitle);
    case 'author':
      rest.sort((a, b) {
        final byAuthor = _author(a).compareTo(_author(b));
        return byAuthor != 0 ? byAuthor : byTitle(a, b);
      });
    case 'rating':
      rest.sort((a, b) {
        final byRating = b.rating.compareTo(a.rating);
        return byRating != 0 ? byRating : byTitle(a, b);
      });
    case 'pubdate':
      final dated = rest.where((m) => m.pubdate.isNotEmpty).toList()
        ..sort((a, b) => b.pubdate.compareTo(a.pubdate));
      final undated = rest.where((m) => m.pubdate.isEmpty).toList()
        ..sort(byTitle);
      rest = [...dated, ...undated];
  }
  return [...merged, ...rest];
}

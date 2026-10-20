/// Tests for metadata result sorting.
library;

import 'package:test/test.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/metadata/sorting.dart';

void main() {
  test('sort metadata by title author rating and newest', () {
    final merged = Metadata(title: 'Merged', sourceId: 'merged');
    final b = Metadata(title: 'Beta', authors: ['Zed'], rating: 2.0, pubdate: '2000');
    final a = Metadata(title: 'Alpha', authors: ['Amy'], rating: 4.0, pubdate: '2020');

    for (final key in ['title', 'author', 'rating', 'pubdate']) {
      final results = sortMetadata([b, merged, a], key);
      expect(results.map((m) => m.title), ['Merged', 'Alpha', 'Beta'],
          reason: 'key=$key');
    }
  });

  test('relevance preserves order', () {
    final first = Metadata(title: 'First');
    final second = Metadata(title: 'Second');
    final results = sortMetadata([first, second], 'relevance');
    expect(results.map((m) => m.title), ['First', 'Second']);
  });

  test('sort keys exposed', () {
    expect(RESULT_SORT_KEYS,
        ['relevance', 'title', 'author', 'rating', 'pubdate']);
    expect(resultSortOptions.map((o) => o.$1), RESULT_SORT_KEYS);
  });
}

/// Metadata lookup engine: aggregates results across registered sources.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/isbn.dart';
import 'metadata.dart';
import 'universal.dart';

class MetadataEngine {
  final List<MetadataSource> _sources = [];

  void registerSource(MetadataSource source) => _sources.add(source);

  List<MetadataSource> sources() => List.of(_sources);

  Future<List<Metadata>> find({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async => _rank(
    await _everySource(
      (source) => source.search(
        title: title,
        authors: authors,
        isbn: isbn,
        client: client,
        timeout: timeout,
      ),
    ),
  );

  Future<Metadata?> grabUrl(
    String url, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 20),
  }) => UniversalGrabber().grab(url, client: client, timeout: timeout);

  Future<List<Metadata>> findQuery(
    String query, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) return [];
    final isbn = queryIsbn(query);
    if (isbn.isNotEmpty) {
      return _withMerged(
        await find(isbn: isbn, client: client, timeout: timeout),
      );
    }
    final results = await _everySource(
      (source) =>
          source.searchFreeText(query, client: client, timeout: timeout),
    );
    return combineQuery(query, results);
  }

  /// Runs [search] against every source in parallel, dropping the ones that
  /// fail so one broken source cannot sink the others.
  Future<List<Metadata>> _everySource(
    Future<List<Metadata>> Function(MetadataSource source) search,
  ) async {
    Future<List<Metadata>> guarded(MetadataSource source) async {
      try {
        return await search(source);
      } catch (_) {
        return const <Metadata>[];
      }
    }

    final perSource = await Future.wait([
      for (final source in _sources) guarded(source),
    ]);
    return [for (final rows in perSource) ...rows];
  }

  Future<List<Metadata>> findAll({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async => _withMerged(
    await find(
      title: title,
      authors: authors,
      isbn: isbn,
      client: client,
      timeout: timeout,
    ),
  );

  /// Canonicalize results gathered from several sources: keep English
  /// entries, dedupe (rating-aware), sort by rating and prepend the merged
  /// record when more than one row remains.
  static List<Metadata> combineSources(List<Metadata> results) =>
      _withMerged(_rank(results));

  /// Rank free-text query results: English only, deduped, then ordered by
  /// fuzzy score and rating; prepend the merged record when >1 row remains.
  static List<Metadata> combineQuery(String query, List<Metadata> results) =>
      _withMerged(_rank(results, query: query));

  /// The one result pipeline: keep English rows before dedupe, so a
  /// non-English duplicate cannot evict the English row it shares a key with,
  /// then dedupe (best rating wins) and, for [query], rank by fuzzy score.
  static List<Metadata> _rank(List<Metadata> results, {String? query}) {
    final deduped = _dedupe([
      for (final meta in results)
        if (_isEnglish(meta)) meta,
    ]);
    if (query != null) {
      deduped.sort((a, b) {
        final byScore = _fuzzyScore(query, b).compareTo(_fuzzyScore(query, a));
        if (byScore != 0) return byScore;
        return b.rating.compareTo(a.rating);
      });
    }
    return deduped;
  }

  static List<Metadata> _withMerged(List<Metadata> results) {
    final merged = mergeResults(results);
    if (merged != null && results.length > 1) {
      return [merged, ...results];
    }
    return results;
  }

  /// Combine fields from every result into one best-effort record.
  static Metadata? mergeResults(List<Metadata> results) {
    if (results.isEmpty) return null;
    if (results.length == 1) return results[0];

    int completeness(Metadata meta) {
      var count = 0;
      if (meta.title.isNotEmpty) count++;
      if (meta.authors.isNotEmpty) count++;
      if (meta.isbn.isNotEmpty) count++;
      if (meta.publisher.isNotEmpty) count++;
      if (meta.pubdate.isNotEmpty) count++;
      if (meta.language.isNotEmpty) count++;
      if (meta.description.isNotEmpty) count++;
      if (meta.coverUrl.isNotEmpty) count++;
      return count;
    }

    var best = results[0];
    for (final meta in results.skip(1)) {
      final c = completeness(meta);
      final bc = completeness(best);
      if (c > bc ||
          (c == bc &&
              (meta.rating > best.rating ||
                  (meta.rating == best.rating &&
                      meta.description.length > best.description.length)))) {
        best = meta;
      }
    }
    final merged = best.copyWith()
      ..sourceId = 'merged'
      ..sourceName = 'Merged sources';

    String firstTruthy(String Function(Metadata) get) {
      for (final meta in results) {
        final value = get(meta);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    if (merged.title.isEmpty) merged.title = firstTruthy((m) => m.title);
    if (merged.isbn.isEmpty) merged.isbn = firstTruthy((m) => m.isbn);
    if (merged.publisher.isEmpty) {
      merged.publisher = firstTruthy((m) => m.publisher);
    }
    if (merged.pubdate.isEmpty) merged.pubdate = firstTruthy((m) => m.pubdate);
    if (merged.language.isEmpty) {
      merged.language = firstTruthy((m) => m.language);
    }

    final descriptions = results
        .map((m) => m.description)
        .where((d) => d.isNotEmpty);
    if (descriptions.isNotEmpty) {
      merged.description = descriptions.reduce(
        (a, b) => a.length >= b.length ? a : b,
      );
    }

    if (merged.coverUrl.isEmpty) {
      merged.coverUrl = firstTruthy((m) => m.coverUrl);
    }

    final authors = <String>[];
    final tags = <String>[];
    for (final meta in results) {
      for (final name in meta.authors) {
        if (!authors.contains(name)) authors.add(name);
      }
      for (final tag in meta.tags) {
        if (!tags.contains(tag)) tags.add(tag);
      }
    }
    merged.authors = authors;
    merged.tags = tags;
    merged.rating = results.fold(0.0, (r, m) => m.rating > r ? m.rating : r);
    return merged;
  }

  /// Fetches a cover for [meta], preferring the source that produced it and
  /// failing over to the next matching source, then to [Metadata.coverUrl].
  Future<Uint8List?> fetchCover(
    Metadata meta, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    for (final source in _sources) {
      if (source.id != meta.sourceId && source.name != meta.sourceName) {
        continue;
      }
      try {
        final data = await source.downloadCover(
          meta,
          client: client,
          timeout: timeout,
        );
        if (data != null && data.isNotEmpty) return data;
      } catch (_) {
        // This source cannot serve it; the next one might.
      }
    }
    if (meta.coverUrl.isEmpty) return null;
    try {
      return await fetchCoverBytes(
        meta.coverUrl,
        client: client,
        timeout: timeout,
      );
    } catch (_) {
      return null;
    }
  }

  static List<Metadata> _dedupe(List<Metadata> results) {
    // Key by ISBN when present, else normalized (title, authors).
    final merged = <Object, Metadata>{};
    final order = <Object>[];
    for (final meta in results) {
      final Object key = meta.isbn.isNotEmpty
          ? ('isbn', meta.isbn)
          : (
              'ta',
              meta.title.toLowerCase(),
              meta.authors.map((a) => a.toLowerCase()).join('\u0000'),
            );
      final existing = merged[key];
      if (existing == null) {
        merged[key] = meta;
        order.add(key);
      } else if (meta.rating > existing.rating) {
        merged[key] = meta;
      }
    }
    final deduped = [for (final key in order) merged[key]!];
    deduped.sort((a, b) => b.rating.compareTo(a.rating));
    return deduped;
  }
}

String _normalize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

bool _isEnglish(Metadata meta) {
  final language = meta.language.trim().toLowerCase();
  if (language.isEmpty) {
    return true; // sources often omit it; don't discard the result
  }
  return language.startsWith('en') ||
      language == 'english' ||
      language == 'eng';
}

/// Ratcliff-Obershelp ratio matching Python's difflib.SequenceMatcher.ratio:
/// 2*M/T where M is the total size of recursive longest matching blocks.
double _ratio(String a, String b) {
  final length = a.length + b.length;
  if (length == 0) return 1.0;
  return 2.0 * _matchingBlocks(a, b) / length;
}

int _matchingBlocks(String a, String b) {
  var total = 0;
  final stack = <List<int>>[
    [0, a.length, 0, b.length],
  ];
  while (stack.isNotEmpty) {
    final range = stack.removeLast();
    final alo = range[0], ahi = range[1], blo = range[2], bhi = range[3];
    // Longest contiguous match.
    var bestSize = 0, bestI = 0, bestJ = 0;
    for (var i = alo; i < ahi; i++) {
      for (var j = blo; j < bhi; j++) {
        var k = 0;
        while (i + k < ahi && j + k < bhi && a[i + k] == b[j + k]) {
          k++;
        }
        if (k > bestSize) {
          bestSize = k;
          bestI = i;
          bestJ = j;
        }
      }
    }
    if (bestSize > 0) {
      total += bestSize;
      if (alo < bestI && blo < bestJ) {
        stack.add([alo, bestI, blo, bestJ]);
      }
      if (bestI + bestSize < ahi && bestJ + bestSize < bhi) {
        stack.add([bestI + bestSize, ahi, bestJ + bestSize, bhi]);
      }
    }
  }
  return total;
}

double _fuzzyScore(String query, Metadata meta) {
  final normalizedQuery = _normalize(query);
  final title = _normalize(meta.title);
  final authors = _normalize(meta.authors.join(', '));
  if (normalizedQuery.isEmpty) return 0.0;

  double score;
  if (normalizedQuery == title) {
    score = 150.0;
  } else if (title.contains(normalizedQuery)) {
    score = 100.0;
  } else if (title.isNotEmpty) {
    score = _ratio(normalizedQuery, title) * 40.0;
    if (normalizedQuery.contains(title)) score += 40.0;
  } else {
    score = 0.0;
  }

  final titleTokens = title.split(' ').toSet();
  final authorTokens = authors.split(' ').toSet();
  for (final token in normalizedQuery.split(' ')) {
    if (titleTokens.contains(token)) score += 12.0;
    if (authorTokens.contains(token)) {
      score += 8.0;
    } else if (authors.contains(token)) {
      score += 4.0;
    }
  }
  score += (meta.rating > 0 ? meta.rating : 0.0) * 2.0;
  if (meta.isbn.isNotEmpty &&
      normalizedQuery.contains(meta.isbn.toLowerCase())) {
    score += 100.0;
  }
  return score;
}

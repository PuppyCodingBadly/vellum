/// Metadata lookup engine: aggregates results across registered sources.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'metadata.dart';
import 'universal.dart';

const int maxCoverBytes = 10 * 1024 * 1024;

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
  }) async {
    // Fan out in parallel; results concatenated in registration order.
    final perSource = await Future.wait(_sources.map((source) async {
      try {
        return await source.search(
            title: title,
            authors: authors,
            isbn: isbn,
            client: client,
            timeout: timeout);
      } catch (_) {
        return <Metadata>[];
      }
    }));
    final results = perSource.expand((list) => list).toList();
    return _dedupe(results).where(_isEnglish).toList();
  }

  Future<Metadata?> grabUrl(String url,
          {http.Client? client,
          Duration timeout = const Duration(seconds: 20)}) =>
      UniversalGrabber().grab(url, client: client, timeout: timeout);

  Future<List<Metadata>> findQuery(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    query = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) return [];
    final isbn = _queryIsbn(query);
    List<Metadata> results;
    if (isbn.isNotEmpty) {
      results = await find(isbn: isbn, client: client, timeout: timeout);
    } else {
      final perSource = await Future.wait(_sources.map((source) async {
        try {
          return await source.searchFreeText(query,
              client: client, timeout: timeout);
        } catch (_) {
          return <Metadata>[];
        }
      }));
      results = perSource.expand((list) => list).toList();
      results = _dedupe(results).where(_isEnglish).toList();
      results.sort((a, b) {
        final byScore = _fuzzyScore(query, b).compareTo(_fuzzyScore(query, a));
        if (byScore != 0) return byScore;
        return b.rating.compareTo(a.rating);
      });
    }
    final merged = mergeResults(results);
    if (merged != null && results.length > 1) {
      return [merged, ...results];
    }
    return results;
  }

  Future<List<Metadata>> findAll({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final results = await find(
        title: title,
        authors: authors,
        isbn: isbn,
        client: client,
        timeout: timeout);
    final merged = mergeResults(results);
    if (merged != null && results.length > 1) {
      return [merged, ...results];
    }
    return results;
  }

  /// Canonicalize results gathered from several sources: keep English
  /// entries, dedupe (rating-aware), sort by rating and prepend the merged
  /// record when more than one source row remains.
  static List<Metadata> combineSources(List<Metadata> results) {
    final combined = _dedupe(results.where(_isEnglish).toList());
    return _withMerged(combined);
  }

  /// Rank free-text query results: English only, deduped, then ordered by
  /// fuzzy score and rating; prepend the merged record when >1 row remains.
  static List<Metadata> combineQuery(String query, List<Metadata> results) {
    final combined = _dedupe(results.where(_isEnglish).toList());
    combined.sort((a, b) {
      final byScore = _fuzzyScore(query, b).compareTo(_fuzzyScore(query, a));
      if (byScore != 0) return byScore;
      return b.rating.compareTo(a.rating);
    });
    return _withMerged(combined);
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

    final descriptions =
        results.map((m) => m.description).where((d) => d.isNotEmpty);
    if (descriptions.isNotEmpty) {
      merged.description =
          descriptions.reduce((a, b) => a.length >= b.length ? a : b);
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

  Future<Uint8List?> fetchCover(Metadata meta,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    for (final source in _sources) {
      if (source.id == meta.sourceId || source.name == meta.sourceName) {
        try {
          return await source.downloadCover(meta,
              client: client, timeout: timeout);
        } catch (_) {
          return null;
        }
      }
    }
    if (meta.coverUrl.isEmpty) return null;
    final httpClient = client ?? http.Client();
    try {
      final request = http.Request('GET', Uri.parse(meta.coverUrl))
        ..headers['User-Agent'] = 'Vellum/0.1 metadata grabber';
      final resp = await httpClient.send(request).timeout(timeout);
      final contentType =
          (resp.headers['content-type'] ?? '').toLowerCase();
      if (contentType.isNotEmpty && !contentType.startsWith('image/')) {
        return null;
      }
      final builder = BytesBuilder();
      var size = 0;
      await for (final chunk in resp.stream) {
        size += chunk.length;
        if (size > maxCoverBytes) return null;
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static List<Metadata> _dedupe(List<Metadata> results) {
    // Key by ISBN when present, else normalized (title, authors).
    final merged = <Object, Metadata>{};
    final order = <Object>[];
    for (final meta in results) {
      final Object key = meta.isbn.isNotEmpty
          ? ('isbn', meta.isbn)
          : ('ta', meta.title.toLowerCase(),
              meta.authors.map((a) => a.toLowerCase()).join('\u0000'));
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

String _queryIsbn(String query) {
  final digits = query.replaceAll(RegExp(r'[^0-9Xx]'), '');
  final isDigit = RegExp(r'^[0-9]+$');
  if (digits.length == 13 && isDigit.hasMatch(digits)) return digits;
  if (digits.length == 10 &&
      isDigit.hasMatch(digits.substring(0, 9)) &&
      (isDigit.hasMatch(digits[9]) || digits[9].toUpperCase() == 'X')) {
    return digits.toUpperCase();
  }
  return '';
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
    [0, a.length, 0, b.length]
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

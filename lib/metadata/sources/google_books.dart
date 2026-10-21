/// Google Books metadata source.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../metadata.dart';

const _apiUrl = 'https://www.googleapis.com/books/v1/volumes';

class GoogleBooks extends MetadataSource {
  @override
  String get id => 'google-books';
  @override
  String get name => 'Google Books';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final parts = <String>[];
    if (title.isNotEmpty) parts.add('intitle:$title');
    for (final author in authors ?? const <String>[]) {
      if (author.isNotEmpty) parts.add('inauthor:$author');
    }
    if (isbn.isNotEmpty) parts.add('isbn:$isbn');
    if (parts.isEmpty) return [];
    return _query(parts.join('+'), client, timeout);
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    query = query.trim();
    if (query.isEmpty) return [];
    return _query(query, client, timeout);
  }

  Future<List<Metadata>> _query(String q, http.Client? client,
      Duration timeout) async {
    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(_apiUrl).replace(queryParameters: {
        'q': q,
        'maxResults': '20',
        'langRestrict': 'en',
      });
      final resp = await httpClient.get(uri).timeout(timeout);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, Object?>;
      final items = (data['items'] as List?) ?? [];
      return [
        for (final item in items)
          if (_parseItem(item as Map<String, Object?>) case final meta?) meta
      ];
    } catch (_) {
      return [];
    } finally {
      if (client == null) httpClient.close();
    }
  }

  @override
  Future<Uint8List?> downloadCover(Metadata meta,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    if (meta.coverUrl.isEmpty) return null;
    final httpClient = client ?? http.Client();
    try {
      final resp = await httpClient.get(Uri.parse(meta.coverUrl)).timeout(timeout);
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Metadata? _parseItem(Map<String, Object?> item) {
    final info = item['volumeInfo'] as Map<String, Object?>?;
    if (info == null || info.isEmpty) return null;
    var isbn = '';
    var isbn10 = '';
    for (final ident
        in (info['industryIdentifiers'] as List?) ?? const []) {
      final map = ident as Map<String, Object?>;
      final value = (map['identifier'] as String?) ?? '';
      if (map['type'] == 'ISBN_13') {
        isbn = value;
        break;
      }
      if (map['type'] == 'ISBN_10' && isbn10.isEmpty) isbn10 = value;
    }
    if (isbn.isEmpty) isbn = isbn10;
    var coverUrl = '';
    final links = info['imageLinks'] as Map<String, Object?>?;
    final thumbnail = links?['thumbnail'] as String?;
    if (thumbnail != null) {
      // Prefer a higher-resolution image than the default thumbnail.
      coverUrl = thumbnail.replaceAll('zoom=1', 'zoom=0');
    }
    final rating = (info['averageRating'] as num?)?.toDouble() ?? 0.0;
    return Metadata(
      title: (info['title'] as String?) ?? '',
      authors:
          (info['authors'] as List?)?.map((e) => e.toString()).toList() ?? [],
      isbn: isbn,
      publisher: (info['publisher'] as String?) ?? '',
      pubdate: (info['publishedDate'] as String?) ?? '',
      language: (info['language'] as String?) ?? '',
      description: (info['description'] as String?) ?? '',
      tags:
          (info['categories'] as List?)?.map((e) => e.toString()).toList() ??
              [],
      rating: rating,
      coverUrl: coverUrl,
      sourceId: (item['id'] as String?) ?? '',
      sourceName: 'Google Books',
    );
  }
}

/// Library of Congress book metadata source.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../metadata.dart';

const _apiUrl = 'https://www.loc.gov/books/';
const _maxCoverBytes = 10 * 1024 * 1024;

class LibraryOfCongress extends MetadataSource {
  @override
  String get id => 'library-of-congress';
  @override
  String get name => 'Library of Congress';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final query = isbn.isNotEmpty
        ? isbn
        : [
            if (title.isNotEmpty) title,
            ...(authors ?? const <String>[]).take(1),
          ].join(' ');
    if (query.isEmpty) return [];
    return _query(query, client, timeout);
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    query = query.trim();
    if (query.isEmpty) return [];
    return _query(query, client, timeout);
  }

  Future<List<Metadata>> _query(
      String query, http.Client? client, Duration timeout) async {
    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(_apiUrl).replace(queryParameters: {
        'q': query,
        'fo': 'json',
        'c': '20',
        'fa': 'language:english',
      });
      final resp = await httpClient.get(uri).timeout(timeout);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, Object?>;
      final results = (data['results'] as List?) ?? [];
      return [
        for (final item in results)
          if (_parseResult(item as Map<String, Object?>) case final meta?) meta
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
      final resp = await httpClient
          .send(http.Request('GET', Uri.parse(meta.coverUrl)))
          .timeout(timeout);
      // No Content-Type check, per the Python source.
      final builder = BytesBuilder();
      var size = 0;
      await for (final chunk in resp.stream) {
        size += chunk.length;
        if (size > _maxCoverBytes) return null;
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Metadata? _parseResult(Map<String, Object?> item) {
    final title = _text(item['title']);
    if (title.isEmpty) return null;
    final extras = (item['item'] as Map<String, Object?>?) ?? {};
    final images = (item['image_url'] as List?) ??
        (extras['image_url'] as List?) ??
        const [];
    var cover = '';
    if (images.isNotEmpty) {
      cover = _text(images[0]).split('#').first;
    }
    final publisher = _text(_or(extras['created_published'], item['publisher']));
    final language = _text(_or(extras['language'], item['language']));
    final isbn = _text(item['number_isbn'] ?? item['isbn']);
    return Metadata(
      title: title,
      authors: _list(item['contributor']),
      isbn: isbn,
      publisher: publisher,
      pubdate: _text(item['date']),
      language: language,
      description: _clean(_text(item['description'])),
      tags: _list(item['subject']).take(8).toList(),
      coverUrl: cover,
      sourceId: 'loc:${_text(item['id'])}',
      sourceName: 'Library of Congress',
    );
  }
}

List<String> _list(Object? value) {
  final values = value is List ? value : [value];
  final result = <String>[];
  for (final item in values) {
    final text = _text(item);
    if (text.isNotEmpty && !result.contains(text)) result.add(text);
  }
  return result;
}

/// Python-style truthiness fallback: empty/null values fall through.
Object? _or(Object? a, Object? b) {
  if (a == null) return b;
  if (a is List && a.isEmpty) return b;
  if (a == '') return b;
  return a;
}

String _text(Object? value) {
  if (value is List) value = value.isEmpty ? '' : value[0];
  return (value?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _clean(String value) {
  final text = value.replaceAll(RegExp(r'<[^>]+>'), ' ');
  return _unescape(text).replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _unescape(String value) {
  final named = value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  return named.replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|\d+);'), (match) {
    final raw = match.group(1)!;
    final code = raw.startsWith('x') || raw.startsWith('X')
        ? int.tryParse(raw.substring(1), radix: 16)
        : int.tryParse(raw);
    if (code == null ||
        code < 0 ||
        code > 0x10FFFF ||
        (code >= 0xD800 && code <= 0xDFFF)) {
      // Out of range or surrogate: U+FFFD replacement character.
      return String.fromCharCode(0xFFFD);
    }
    return String.fromCharCode(code);
  });
}

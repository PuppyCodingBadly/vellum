/// Internet Archive book metadata source.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../metadata.dart';

const _apiUrl = 'https://archive.org/advancedsearch.php';
const _maxCoverBytes = 10 * 1024 * 1024;
const _fields = [
  'identifier',
  'title',
  'creator',
  'date',
  'publisher',
  'language',
  'description',
  'subject',
  'isbn',
];

class InternetArchive extends MetadataSource {
  @override
  String get id => 'internet-archive';
  @override
  String get name => 'Internet Archive';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final clauses = <String>[];
    if (isbn.isNotEmpty) clauses.add('isbn:($isbn)');
    if (title.isNotEmpty) clauses.add('title:($title)');
    for (final author in (authors ?? const <String>[]).take(1)) {
      if (author.isNotEmpty) clauses.add('creator:($author)');
    }
    if (clauses.isEmpty) return [];
    return _query(
      '${clauses.join(' AND ')} AND mediatype:texts AND language:(eng OR English)',
      client,
      timeout,
    );
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    query = query.trim();
    if (query.isEmpty) return [];
    return _query(
      '($query) AND mediatype:texts AND language:(eng OR English)',
      client,
      timeout,
    );
  }

  Future<List<Metadata>> _query(
      String q, http.Client? client, Duration timeout) async {
    final httpClient = client ?? http.Client();
    try {
      // fl[] must be repeated per field.
      final params = StringBuffer('q=${Uri.encodeQueryComponent(q)}');
      for (final field in _fields) {
        params.write('&fl%5B%5D=${Uri.encodeQueryComponent(field)}');
      }
      params.write('&rows=20&output=json');
      final resp =
          await httpClient.get(Uri.parse('$_apiUrl?$params')).timeout(timeout);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, Object?>;
      final docs =
          ((data['response'] as Map<String, Object?>?)?['docs'] as List?) ??
              [];
      return [
        for (final doc in docs)
          if (_parseDoc(doc as Map<String, Object?>) case final meta?) meta
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
      final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
      if (contentType.isNotEmpty && !contentType.startsWith('image/')) {
        return null;
      }
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

  static Metadata? _parseDoc(Map<String, Object?> doc) {
    final identifier = _text(doc['identifier']);
    final title = _text(doc['title']);
    if (identifier.isEmpty || title.isEmpty) return null;
    return Metadata(
      title: title,
      authors: _list(doc['creator']),
      isbn: _isbn(doc['isbn']),
      publisher: _text(doc['publisher']),
      pubdate: _text(doc['date']),
      language: _text(doc['language']),
      description: _clean(_text(doc['description'])),
      tags: _list(doc['subject']).take(8).toList(),
      coverUrl:
          'https://archive.org/services/img/${Uri.encodeComponent(identifier)}',
      sourceId: 'internet-archive:$identifier',
      sourceName: 'Internet Archive',
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

String _isbn(Object? value) {
  final values = _list(value);
  for (final candidate in values) {
    final digits = candidate.replaceAll(RegExp(r'[^0-9Xx]'), '');
    if (digits.length == 13 && RegExp(r'^[0-9]+$').hasMatch(digits)) {
      return digits;
    }
  }
  for (final candidate in values) {
    final digits = candidate.replaceAll(RegExp(r'[^0-9Xx]'), '');
    if (digits.length == 10) return digits.toUpperCase();
  }
  return values.isEmpty ? '' : values[0];
}

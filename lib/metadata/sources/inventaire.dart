/// Inventaire (Wikidata-centered) book metadata source.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../metadata.dart';

const _apiUrl = 'https://inventaire.io/api/search';
const _entitiesUrl = 'https://inventaire.io/api/entities';
const _baseUrl = 'https://inventaire.io';
const _maxCoverBytes = 10 * 1024 * 1024;
const _batch = 40;

class Inventaire extends MetadataSource {
  @override
  String get id => 'inventaire';
  @override
  String get name => 'Inventaire';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
  }) async {
    if (isbn.isNotEmpty) return _search(isbn, 'editions', client);
    final query = [
      if (title.isNotEmpty) title,
      ...(authors ?? const <String>[]).take(1),
    ].join(' ');
    if (query.isEmpty) return [];
    return _search(query, 'works', client);
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client}) async {
    query = query.trim();
    if (query.isEmpty) return [];
    return _search(query, 'works', client);
  }

  Future<List<Metadata>> _search(
      String query, String entityType, http.Client? client) async {
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final searchUri = Uri.parse(_apiUrl).replace(queryParameters: {
        'search': query,
        'types': entityType,
        'limit': '20',
      });
      final resp = await httpClient.get(searchUri);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, Object?>;
      final results = [
        for (final item in (data['results'] as List?) ?? const [])
          if ((item as Map<String, Object?>)['uri'] != null) item
      ];
      var entities = await _fetchEntities(
        httpClient,
        [for (final item in results) item['uri'] as String],
      );

      final related = <String>{};
      for (final entity in entities.values) {
        for (final prop in ['P50', 'P123', 'P136', 'P407', 'P629']) {
          related.addAll(_claims(entity, prop));
        }
      }
      related.removeAll(entities.keys);
      if (related.isNotEmpty) {
        entities = {
          ...entities,
          ...await _fetchEntities(httpClient, related.toList()..sort()),
        };
      }

      return [
        for (final result in results)
          if (_parse(result, entities) case final meta?) meta
      ];
    } catch (_) {
      return [];
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  Future<Map<String, Map<String, Object?>>> _fetchEntities(
      http.Client httpClient, List<String> uris) async {
    final entities = <String, Map<String, Object?>>{};
    for (var start = 0; start < uris.length; start += _batch) {
      final chunk = uris.sublist(
          start, start + _batch > uris.length ? uris.length : start + _batch);
      if (chunk.isEmpty) continue;
      try {
        final uri = Uri.parse(_entitiesUrl).replace(queryParameters: {
          'action': 'by-uris',
          'uris': chunk.join('|'),
        });
        final resp = await httpClient.get(uri);
        if (resp.statusCode != 200) continue;
        final data = jsonDecode(resp.body) as Map<String, Object?>;
        final fetched = (data['entities'] as Map?) ?? {};
        for (final entry in fetched.entries) {
          entities[entry.key as String] =
              (entry.value as Map).cast<String, Object?>();
        }
      } catch (_) {
        continue;
      }
    }
    return entities;
  }

  @override
  Future<Uint8List?> downloadCover(Metadata meta, {http.Client? client}) async {
    if (meta.coverUrl.isEmpty) return null;
    final httpClient = client ?? http.Client();
    try {
      final resp =
          await httpClient.send(http.Request('GET', Uri.parse(meta.coverUrl)));
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

  Metadata? _parse(Map<String, Object?> result,
      Map<String, Map<String, Object?>> entities) {
    final entity = entities[(result['uri'] as String?) ?? ''];
    if (entity == null) return null;
    Map<String, Object?>? work;
    for (final uri in _claims(entity, 'P629')) {
      work = entities[uri];
      if (work != null) break;
    }

    final entityLabel = _labelEn(entity);
    final title = (entityLabel == null || entityLabel.isEmpty)
        ? _labelEn(work)
        : entityLabel;
    if (title == null || title.isEmpty) return null;

    List<String> resolve(String prop, {bool workFirst = false}) {
      final first = workFirst ? work : entity;
      final second = workFirst ? entity : work;
      var uris = _claims(first, prop);
      if (uris.isEmpty) uris = _claims(second, prop);
      return [
        for (final uri in uris)
          if (_labelEn(entities[uri]) case final label?) label
      ].where((l) => l.isNotEmpty).toList();
    }

    final authors = resolve('P50');
    final publishers = resolve('P123');
    final languages = resolve('P407');
    final tags = resolve('P136', workFirst: true).take(8).toList();

    String firstClaim(String prop) {
      var values = _claims(entity, prop);
      if (values.isEmpty) values = _claims(work, prop);
      return values.isEmpty ? '' : values[0];
    }

    final description = _descriptionEn(entity).isNotEmpty
        ? _descriptionEn(entity)
        : _descriptionEn(work);
    final image = (result['image'] as String?)?.isNotEmpty == true
        ? result['image'] as String
        : (entity['image'] as String?)?.isNotEmpty == true
            ? entity['image'] as String
            : (work?['image'] as String?) ?? '';
    return Metadata(
      title: title,
      authors: authors,
      isbn: _cleanIsbn(firstClaim('P212')),
      publisher: publishers.isEmpty ? '' : publishers[0],
      pubdate: firstClaim('P577'),
      language: languages.isEmpty ? 'English' : languages[0],
      description: description,
      tags: tags,
      coverUrl: _imageUrl(image),
      sourceId:
          'inventaire:${(entity['wdId'] as String?) ?? (result['id'] as String?) ?? ''}',
      sourceName: 'Inventaire',
    );
  }
}

List<String> _claims(Map<String, Object?>? entity, String prop) {
  if (entity == null) return [];
  final claims = entity['claims'] as Map<String, Object?>?;
  final values = claims?['wdt:$prop'] as List?;
  return [for (final value in values ?? const []) value.toString()];
}

String? _labelEn(Map<String, Object?>? entity) {
  if (entity == null) return null;
  final labels = entity['labels'] as Map<String, Object?>?;
  return ((labels?['en'] as String?) ?? '').trim();
}

String _descriptionEn(Map<String, Object?>? entity) {
  if (entity == null) return '';
  final descriptions = entity['descriptions'] as Map<String, Object?>?;
  return ((descriptions?['en'] as String?) ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _imageUrl(Object? value) {
  final text = (value?.toString() ?? '').trim();
  if (text.isEmpty) return '';
  if (text.startsWith('http://') || text.startsWith('https://')) return text;
  if (text.startsWith('/')) return '$_baseUrl$text';
  return '$_baseUrl/img/entities/$text';
}

String _cleanIsbn(String value) {
  final digits = value.replaceAll(RegExp(r'[^0-9Xx]'), '');
  if (digits.length == 10 || digits.length == 13) return digits.toUpperCase();
  return '';
}

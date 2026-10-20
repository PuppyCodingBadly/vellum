/// Best-effort metadata extraction from an arbitrary book page URL.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'metadata.dart';

const String userAgent =
    'Vellum/0.1 (+https://github.com/PuppyCodingBadly/vellum) metadata grabber';
const int maxHtmlBytes = 4 * 1024 * 1024;
const int maxCoverBytes = 10 * 1024 * 1024;
const _bookTypes = {'book', 'audiobook', 'product', 'creativework'};

class UniversalGrabber extends MetadataSource {
  @override
  String get id => 'universal-url';
  @override
  String get name => 'Web page';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
  }) async =>
      [];

  Future<Metadata?> grab(String url, {http.Client? client}) async {
    final normalized = normalizeUrl(url);
    if (normalized.isEmpty) {
      throw FormatException('enter a valid http(s) URL');
    }
    final (html, finalUrl) = await _fetchHtml(normalized, client);
    final meta = parseBookPage(html, finalUrl);
    if (meta == null) return null;
    meta.sourceId = 'universal:$finalUrl';
    if (meta.sourceName.isEmpty) {
      meta.sourceName = Uri.parse(finalUrl).host;
    }
    return meta;
  }

  @override
  Future<Uint8List?> downloadCover(Metadata meta, {http.Client? client}) async {
    if (meta.coverUrl.isEmpty) return null;
    try {
      return await _fetchCover(meta.coverUrl, client);
    } catch (_) {
      return null;
    }
  }
}

/// Return a validated http(s) URL, or "" for a search string/invalid input.
String normalizeUrl(String url) {
  url = url.trim();
  if (url.isEmpty || url.split('').any((c) => c.trim().isEmpty)) return '';
  if (!RegExp('^https?://', caseSensitive: false).hasMatch(url)) {
    url = 'https://$url';
  }
  Uri parts;
  try {
    parts = Uri.parse(url);
  } catch (_) {
    return '';
  }
  final scheme = parts.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || parts.host.isEmpty) return '';
  final host = parts.host;
  if (host.split('').any((c) => c.trim().isEmpty)) return '';
  if (!host.contains('.') && host != 'localhost') return '';
  if (!url.contains('://')) return '';
  return url;
}

Future<(String, String)> _fetchHtml(String url, http.Client? client) async {
  final httpClient = client ?? http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = userAgent;
    final resp = await httpClient.send(request);
    if (resp.statusCode < 200 || resp.statusCode >= 400) {
      throw http.ClientException('HTTP ${resp.statusCode}', request.url);
    }
    final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
    if (contentType.isNotEmpty &&
        !contentType.contains('html') &&
        !contentType.contains('xml')) {
      throw FormatException('not an HTML page ($contentType)');
    }
    final builder = BytesBuilder();
    var size = 0;
    await for (final chunk in resp.stream) {
      size += chunk.length;
      if (size > maxHtmlBytes) break; // truncate, don't fail
      builder.add(chunk);
    }
    final body = builder.takeBytes();
    return (utf8.decode(body, allowMalformed: true),
        resp.request?.url.toString() ?? url);
  } finally {
    if (client == null) httpClient.close();
  }
}

Future<Uint8List?> _fetchCover(String url, http.Client? client) async {
  if (!RegExp('^https?://', caseSensitive: false).hasMatch(url)) return null;
  final httpClient = client ?? http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = userAgent;
    final resp = await httpClient.send(request);
    if (resp.statusCode < 200 || resp.statusCode >= 400) return null;
    final contentType = (resp.headers['content-type'] ?? '').toLowerCase();
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
  } finally {
    if (client == null) httpClient.close();
  }
}

/// Parse a book page into Metadata using every embedded convention.
Metadata? parseBookPage(String html, [String baseUrl = '']) {
  final document = html_parser.parse(html);
  final fields = <String, Object>{};

  for (final obj in _jsonldObjects(document)) {
    if (_isBookType(obj)) {
      _mergeMissing(fields, _fieldsFromJsonld(obj, baseUrl));
    }
  }
  _mergeMissing(fields, _fieldsFromMeta(document, baseUrl));
  _mergeMissing(fields, _fieldsFromMicrodata(document, baseUrl));

  var title = (fields['title'] as String?) ?? '';
  if (title.isEmpty) {
    title = _clean(document.querySelector('title')?.text ?? '');
  }
  if (title.isEmpty) return null;

  return Metadata(
    title: title,
    authors:
        (fields['authors'] as List<String>?) ?? [],
    isbn: (fields['isbn'] as String?) ?? '',
    publisher: (fields['publisher'] as String?) ?? '',
    pubdate: (fields['pubdate'] as String?) ?? '',
    language: (fields['language'] as String?) ?? '',
    description: (fields['description'] as String?) ?? '',
    tags: (fields['tags'] as List<String>?) ?? [],
    rating: _clampRating(fields['rating'] ?? 0.0),
    coverUrl: (fields['cover_url'] as String?) ?? '',
    sourceName: (fields['site_name'] as String?) ?? '',
  );
}

// -- JSON-LD -----------------------------------------------------------------

List<Map<String, Object?>> _jsonldObjects(Document document) {
  final objects = <Map<String, Object?>>[];
  for (final script
      in document.querySelectorAll('script[type="application/ld+json"]')) {
    final raw = script.text;
    if (raw.trim().isEmpty) continue;
    Object? data;
    try {
      data = jsonDecode(_unescapeHtml(raw));
    } catch (_) {
      continue;
    }
    objects.addAll(_flattenJsonld(data));
  }
  return objects;
}

String _unescapeHtml(String value) => value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");

List<Map<String, Object?>> _flattenJsonld(Object? data) {
  if (data is List) {
    return [for (final item in data) ..._flattenJsonld(item)];
  }
  if (data is! Map) return [];
  final map = data.cast<String, Object?>();
  final graph = map['@graph'];
  if (graph is List) return _flattenJsonld(graph);
  return [map];
}

bool _isBookType(Map<String, Object?> obj) {
  var types = obj['@type'] ?? obj['type'] ?? '';
  if (types is String) types = [types];
  if (types is! List) return false;
  return types.any((value) => _bookTypes
      .contains(value.toString().split('/').last.toLowerCase()));
}

Map<String, Object> _fieldsFromJsonld(
    Map<String, Object?> obj, String baseUrl) {
  final fields = <String, Object>{};
  void put(String key, Object? value) {
    if (value == null) return;
    if (value is String && value.isEmpty) return;
    if (value is List && value.isEmpty) return;
    if (value is num && value == 0) return;
    fields[key] = value;
  }

  put('title', _clean(_asText(obj['name'] ?? obj['headline'])));
  put('authors', _names(obj['author']));
  put('isbn', _jsonldIsbn(obj));
  put('publisher', _asText(obj['publisher']));
  put(
      'pubdate',
      _asText(
          obj['datePublished'] ?? obj['dateCreated'] ?? obj['releaseDate']));
  put('language', _asText(obj['inLanguage']));
  put('description', _clean(_asText(obj['description'])));
  put('cover_url', _firstUrl(obj['image'] ?? obj['thumbnailUrl'], baseUrl));
  put('rating', _jsonldRating(obj['aggregateRating']));
  put('tags', _splitTags(obj['genre'] ?? obj['keywords']));
  return fields;
}

String _jsonldIsbn(Map<String, Object?> obj) {
  final candidates = <Object?>[];
  if (obj['isbn'] != null && obj['isbn'] != '') candidates.add(obj['isbn']);
  final identifier = obj['identifier'];
  if (identifier is List) {
    candidates.addAll(identifier);
  } else if (identifier != null) {
    candidates.add(identifier);
  }
  for (final candidate in candidates) {
    if (candidate is Map) {
      final map = candidate.cast<String, Object?>();
      final value = map['value'] ?? map['identifier'];
      final kind = (map['propertyID'] ?? map['name'] ?? map['@type'] ?? '')
          .toString()
          .toLowerCase();
      if (value != null &&
          value.toString().isNotEmpty &&
          (kind.isEmpty || kind.contains('isbn'))) {
        return _clean(value.toString());
      }
    } else if (candidate != null && candidate.toString().isNotEmpty) {
      return _clean(candidate.toString());
    }
  }
  for (final key in ['gtin13', 'gtin', 'sku']) {
    final value = obj[key];
    if (value != null && value.toString().isNotEmpty) {
      return _clean(value.toString());
    }
  }
  return '';
}

double _jsonldRating(Object? rating) {
  if (rating is! Map) return 0.0;
  final map = rating.cast<String, Object?>();
  final value = double.tryParse(map['ratingValue']?.toString() ?? '');
  final best = double.tryParse(map['bestRating']?.toString() ?? '') ?? 5;
  if (value == null || best <= 0) return 0.0;
  return _clampRating(value * 5.0 / best);
}

// -- meta tags ---------------------------------------------------------------

Map<String, Object> _fieldsFromMeta(Document document, String baseUrl) {
  List<String> values(List<String> names) {
    final found = <String>[];
    for (final name in names) {
      for (final tag in document.querySelectorAll('meta[property="$name"]')) {
        final content = tag.attributes['content'];
        if (content != null && content.isNotEmpty) {
          found.add(_clean(content));
        }
      }
      for (final tag in document.querySelectorAll('meta[name="$name"]')) {
        final content = tag.attributes['content'];
        if (content != null && content.isNotEmpty) {
          found.add(_clean(content));
        }
      }
    }
    return found;
  }

  String content(List<String> names) {
    final found = values(names);
    return found.isEmpty ? '' : found[0];
  }

  final fields = <String, Object>{};
  final title = content(['og:title', 'twitter:title']);
  if (title.isNotEmpty) fields['title'] = title;
  final authors =
      _splitList(values(['book:author', 'og:book:author', 'author']));
  if (authors.isNotEmpty) fields['authors'] = authors;
  final isbn = content(['book:isbn', 'og:book:isbn', 'isbn']);
  if (isbn.isNotEmpty) fields['isbn'] = isbn;
  final publisher = content(['book:publisher', 'og:book:publisher', 'publisher']);
  if (publisher.isNotEmpty) fields['publisher'] = publisher;
  final pubdate = content([
    'book:release_date',
    'og:book:release_date',
    'article:published_time',
    'date'
  ]);
  if (pubdate.isNotEmpty) fields['pubdate'] = pubdate;
  final language = content(['og:locale', 'language']);
  if (language.isNotEmpty) fields['language'] = language;
  final description =
      content(['og:description', 'twitter:description', 'description']);
  if (description.isNotEmpty) fields['description'] = description;
  var cover =
      content(['og:image:secure_url', 'og:image', 'twitter:image', 'image']);
  if (cover.isNotEmpty) {
    cover = _absolute(cover, baseUrl);
    if (cover.isNotEmpty) fields['cover_url'] = cover;
  }
  final tags = _splitTags(values(['book:tag', 'article:tag', 'keywords']));
  if (tags.isNotEmpty) fields['tags'] = tags;
  final siteName = content(['og:site_name']);
  if (siteName.isNotEmpty) fields['site_name'] = siteName;
  return fields;
}

// -- microdata ---------------------------------------------------------------

Map<String, Object> _fieldsFromMicrodata(Document document, String baseUrl) {
  final scopes = document.querySelectorAll(
      '[itemtype*="Book"], [itemtype*="Product"], [itemtype*="CreativeWork"]');
  final Element scope = scopes.isEmpty ? document.documentElement! : scopes[0];

  String value(String name) {
    final tag = scope.querySelector('[itemprop="$name"]');
    if (tag == null) return '';
    return _clean(tag.attributes['content'] ??
        tag.attributes['href'] ??
        tag.attributes['src'] ??
        tag.text.trim());
  }

  final fields = <String, Object>{};
  final title = value('name');
  if (title.isNotEmpty) fields['title'] = title;
  final author = value('author');
  if (author.isNotEmpty) fields['authors'] = [author];
  final isbn = value('isbn');
  if (isbn.isNotEmpty) fields['isbn'] = isbn;
  final publisher = value('publisher');
  if (publisher.isNotEmpty) fields['publisher'] = publisher;
  final pubdate = value('datePublished');
  if (pubdate.isNotEmpty) fields['pubdate'] = pubdate;
  final description = value('description');
  if (description.isNotEmpty) fields['description'] = description;
  final language = value('inLanguage');
  if (language.isNotEmpty) fields['language'] = language;
  var image = value('image');
  if (image.isNotEmpty) {
    image = _absolute(image, baseUrl);
    if (image.isNotEmpty) fields['cover_url'] = image;
  }
  return fields;
}

// -- helpers -----------------------------------------------------------------

void _mergeMissing(Map<String, Object> target, Map<String, Object> source) {
  source.forEach((key, value) {
    final existing = target[key];
    final missing = existing == null ||
        (existing is String && existing.isEmpty) ||
        (existing is List && existing.isEmpty);
    if (missing) target[key] = value;
  });
}

String _asText(Object? value) {
  if (value is String) return value;
  if (value is Map) {
    final map = value.cast<String, Object?>();
    return _asText(map['name'] ?? map['@value'] ?? map['value']);
  }
  if (value is List) return value.isEmpty ? '' : _asText(value[0]);
  return '';
}

List<String> _names(Object? value) {
  final values = value is List ? value : [value];
  final names = <String>[];
  for (final item in values) {
    final name = _clean(_asText(item));
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  return names;
}

List<String> _splitTags(Object? value) {
  final values = value is List ? value : [value];
  final tags = <String>[];
  for (final item in values) {
    for (var tag in (item?.toString() ?? '').split(RegExp(r'[,;]'))) {
      tag = _clean(tag);
      if (tag.isNotEmpty && !tags.contains(tag)) tags.add(tag);
    }
  }
  return tags.take(12).toList();
}

/// Split repeated meta values without treating author commas as separators.
List<String> _splitList(Object? value) {
  final values = value is List ? value : [value];
  final items = <String>[];
  for (final item in values) {
    final text = _clean(item);
    if (text.isNotEmpty && !items.contains(text)) items.add(text);
  }
  return items;
}

String _firstUrl(Object? value, String baseUrl) {
  final values = value is List ? value : [value];
  for (final item in values) {
    final Object? raw = item is Map
        ? (item.cast<String, Object?>()['url'] ??
            item.cast<String, Object?>()['contentUrl'])
        : item;
    final url = _absolute(_asText(raw), baseUrl);
    if (url.isNotEmpty) return url;
  }
  return '';
}

String _absolute(String value, String baseUrl) {
  value = value.trim();
  if (value.isEmpty) return '';
  if (value.startsWith('//')) return 'https:$value';
  if (RegExp('^https?://', caseSensitive: false).hasMatch(value)) return value;
  if (baseUrl.isNotEmpty) {
    return Uri.parse(baseUrl).resolve(value).toString();
  }
  return '';
}

String _clean(Object? value) {
  var text = value?.toString() ?? '';
  if (text.contains('<') && text.contains('>')) {
    text = html_parser.parse(text).documentElement?.text.trim() ?? '';
    // parse wraps in html/body; text of body
  }
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

double _clampRating(Object? value) {
  final rating =
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');
  if (rating == null) return 0.0;
  final clamped = rating < 0.0
      ? 0.0
      : rating > 5.0
          ? 5.0
          : rating;
  return (clamped * 10).round() / 10;
}

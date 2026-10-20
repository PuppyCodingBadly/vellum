/// Open Library metadata source.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../metadata.dart';

const _apiUrl = 'https://openlibrary.org/search.json';

class OpenLibrary extends MetadataSource {
  @override
  String get id => 'openlibrary';
  @override
  String get name => 'Open Library';

  static const _fields =
      'key,title,author_name,first_publish_year,publisher,'
      'language,subject,cover_i,isbn';

  @override
  Future<List<Metadata>> search({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
  }) async {
    final authorsList = authors ?? const <String>[];
    if (title.isEmpty && authorsList.isEmpty && isbn.isEmpty) return [];
    final params = <String, String>{
      'limit': '20',
      'language': 'eng',
      // Without an explicit fields list the search API omits ISBNs.
      'fields': _fields,
    };
    if (title.isNotEmpty) params['title'] = title;
    if (authorsList.isNotEmpty) params['author'] = authorsList[0];
    if (isbn.isNotEmpty) params['isbn'] = isbn;
    return _query(params, client);
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client}) async {
    query = query.trim();
    if (query.isEmpty) return [];
    return _query({
      'q': query,
      'limit': '20',
      'language': 'eng',
      'fields': _fields,
    }, client);
  }

  Future<List<Metadata>> _query(
      Map<String, String> params, http.Client? client) async {
    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(_apiUrl).replace(queryParameters: params);
      final resp = await httpClient.get(uri);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, Object?>;
      final docs = (data['docs'] as List?) ?? [];
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
  Future<Uint8List?> downloadCover(Metadata meta, {http.Client? client}) async {
    if (meta.coverUrl.isEmpty) return null;
    final httpClient = client ?? http.Client();
    try {
      final resp = await httpClient.get(Uri.parse(meta.coverUrl));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Metadata? _parseDoc(Map<String, Object?> doc) {
    final title = (doc['title'] as String?) ?? '';
    if (title.isEmpty) return null;
    final isbns =
        (doc['isbn'] as List?)?.map((e) => e.toString()).toList() ?? [];
    var isbn = '';
    for (final candidate in isbns) {
      if (candidate.length == 13) {
        isbn = candidate;
        break;
      }
    }
    if (isbn.isEmpty && isbns.isNotEmpty) isbn = isbns[0];
    final coverId = doc['cover_i'];
    final pubdate = doc['first_publish_year'];
    String firstOf(String key) {
      final list = doc[key] as List?;
      return list == null || list.isEmpty ? '' : list[0].toString();
    }

    return Metadata(
      title: title,
      authors: (doc['author_name'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      isbn: isbn,
      publisher: firstOf('publisher'),
      pubdate: pubdate != null && pubdate != 0 ? pubdate.toString() : '',
      language: firstOf('language'),
      description: '',
      tags:
          ((doc['subject'] as List?)?.map((e) => e.toString()).toList() ?? [])
              .take(8)
              .toList(),
      rating: 0.0,
      coverUrl: coverId != null
          ? 'https://covers.openlibrary.org/b/id/$coverId-L.jpg'
          : '',
      sourceId: (doc['key'] as String?) ?? '',
      sourceName: 'Open Library',
    );
  }
}

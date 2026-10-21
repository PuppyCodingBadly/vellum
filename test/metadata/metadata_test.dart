/// Tests for metadata sources and engine. All network access is mocked.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/metadata/sources/google_books.dart';
import 'package:vellum/metadata/sources/openlibrary.dart';

const googlePayload = {
  'items': [
    {
      'id': 'gb-1',
      'volumeInfo': {
        'title': 'Example Book',
        'authors': ['Jane Doe', 'John Smith'],
        'industryIdentifiers': [
          {'type': 'ISBN_10', 'identifier': '0123456789'},
          {'type': 'ISBN_13', 'identifier': '9780123456789'},
        ],
        'publisher': 'Example Press',
        'publishedDate': '2020-05-01',
        'language': 'en',
        'description': 'A fine book.',
        'categories': ['Fiction', 'Adventure'],
        'averageRating': 4.5,
        'imageLinks': {'thumbnail': 'http://books.google.com/img?zoom=1&id=x'},
      },
    }
  ]
};

const openLibraryPayload = {
  'docs': [
    {
      'key': '/works/OL1W',
      'title': 'Example Book',
      'author_name': ['Jane Doe'],
      'isbn': ['0123456789', '9780123456789'],
      'publisher': ['Example Press', 'Other Press'],
      'first_publish_year': 2020,
      'language': ['eng'],
      'subject': [
        'Fiction',
        'Adventure',
        'Drama',
        'History',
        'Magic',
        'Mystery',
        'Romance',
        'Science',
        'Travel'
      ],
      'cover_i': 12345,
    }
  ]
};

http.Client jsonClient(Object? payload, {List<http.Request>? captured}) {
  return MockClient((request) async {
    captured?.add(request);
    return http.Response(jsonEncode(payload), 200,
        headers: {'content-type': 'application/json'});
  });
}

http.Client failingClient() =>
    MockClient((request) async => throw Exception('boom'));

class _StubSource extends MetadataSource {
  @override
  final String id;
  @override
  final String name;
  final List<Metadata> results;
  final bool throws;
  int coverCalls = 0;
  Uint8List? cover;
  List<Metadata>? freeTextResults;
  List<String> isbnSearches = [];

  _StubSource(this.id, this.results,
      {this.name = '', this.throws = false, this.cover, this.freeTextResults});

  @override
  Future<List<Metadata>> search(
      {String title = '',
      List<String>? authors,
      String isbn = '',
      http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    if (isbn.isNotEmpty) isbnSearches.add(isbn);
    if (throws) throw Exception('source exploded');
    return results;
  }

  @override
  Future<List<Metadata>> searchFreeText(String query,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    return freeTextResults ??
        super.searchFreeText(query, client: client, timeout: timeout);
  }

  @override
  Future<Uint8List?> downloadCover(Metadata meta,
      {http.Client? client,
      Duration timeout = const Duration(seconds: 15)}) async {
    coverCalls++;
    return cover;
  }
}

void main() {
  group('GoogleBooks', () {
    test('mapping', () async {
      final captured = <http.Request>[];
      final source = GoogleBooks();
      final results = await source.search(
          title: 'Example Book',
          authors: ['Jane Doe'],
          client: jsonClient(googlePayload, captured: captured));
      expect(results, hasLength(1));
      final meta = results[0];
      expect(meta.title, 'Example Book');
      expect(meta.authors, ['Jane Doe', 'John Smith']);
      expect(meta.isbn, '9780123456789'); // ISBN_13 preferred over ISBN_10
      expect(meta.publisher, 'Example Press');
      expect(meta.pubdate, '2020-05-01');
      expect(meta.language, 'en');
      expect(meta.tags, ['Fiction', 'Adventure']); // from categories
      expect(meta.rating, 4.5);
      expect(meta.coverUrl,
          'http://books.google.com/img?zoom=0&id=x'); // zoom tweak
      expect(meta.sourceId, 'gb-1');
      expect(meta.sourceName, 'Google Books');
      final params = captured.single.url.queryParameters;
      expect(params['q'], contains('intitle:Example Book'));
      expect(params['q'], contains('inauthor:Jane Doe'));
      expect(params['maxResults'], '20');
    });

    test('error returns empty', () async {
      expect(await GoogleBooks().search(title: 'x', client: failingClient()),
          isEmpty);
    });

    test('multiword uses free text', () async {
      final captured = <http.Request>[];
      await GoogleBooks().searchFreeText('dune frank herbert',
          client: jsonClient({'items': []}, captured: captured));
      expect(captured.single.url.queryParameters['q'], 'dune frank herbert');
    });

    test('download cover', () async {
      final client = MockClient((request) async =>
          http.Response.bytes(Uint8List.fromList('IMG'.codeUnits), 200));
      final meta = Metadata(coverUrl: 'http://x/cover.jpg');
      final bytes = await GoogleBooks().downloadCover(meta, client: client);
      expect(String.fromCharCodes(bytes!), 'IMG');
    });
  });

  group('OpenLibrary', () {
    test('mapping', () async {
      final captured = <http.Request>[];
      final results = await OpenLibrary().search(
          title: 'Example Book',
          client: jsonClient(openLibraryPayload, captured: captured));
      expect(results, hasLength(1));
      final meta = results[0];
      expect(meta.title, 'Example Book');
      expect(meta.authors, ['Jane Doe']);
      expect(meta.isbn, '9780123456789'); // 13-digit preferred
      expect(meta.publisher, 'Example Press');
      expect(meta.pubdate, '2020');
      expect(meta.language, 'eng');
      expect(meta.tags, hasLength(8)); // subject[:8]
      expect(
          meta.coverUrl, 'https://covers.openlibrary.org/b/id/12345-L.jpg');
      expect(meta.sourceId, '/works/OL1W');
      expect(meta.sourceName, 'Open Library');
      final params = captured.single.url.queryParameters;
      expect(params['title'], 'Example Book');
      expect(params['limit'], '20');
      expect(params['fields'],
          'key,title,author_name,first_publish_year,publisher,language,subject,cover_i,isbn');
    });

    test('error returns empty', () async {
      expect(await OpenLibrary().search(title: 'x', client: failingClient()),
          isEmpty);
    });

    test('multiword uses free text', () async {
      final captured = <http.Request>[];
      await OpenLibrary().searchFreeText('dune frank herbert',
          client: jsonClient({'docs': []}, captured: captured));
      expect(captured.single.url.queryParameters['q'], 'dune frank herbert');
    });

    test('download cover', () async {
      final client = MockClient((request) async =>
          http.Response.bytes(Uint8List.fromList('IMG'.codeUnits), 200));
      final meta = Metadata(
          coverUrl: 'https://covers.openlibrary.org/b/id/1-L.jpg');
      final bytes = await OpenLibrary().downloadCover(meta, client: client);
      expect(String.fromCharCodes(bytes!), 'IMG');
    });
  });

  group('MetadataEngine', () {
    test('dedupes by isbn and sorts rating desc', () async {
      final low = Metadata(
          title: 'Book', authors: ['A'], isbn: '111', rating: 3.0, sourceId: 's1');
      final high = Metadata(
          title: 'Book', authors: ['A'], isbn: '111', rating: 4.5, sourceId: 's2');
      final other = Metadata(
          title: 'Other', authors: ['B'], isbn: '222', rating: 4.0, sourceId: 's1');
      final engine = MetadataEngine()
        ..registerSource(_StubSource('s1', [low, other]))
        ..registerSource(_StubSource('s2', [high]));
      final results = await engine.find(title: 'Book');
      expect(results, hasLength(2));
      expect(results[0].rating, 4.5);
      expect(results[0].sourceId, 's2'); // higher-rating copy kept
      expect(results[1].rating, 4.0);
    });

    test('dedupes by title+authors without isbn', () async {
      final a = Metadata(title: 'Same', authors: ['X'], rating: 1.0);
      final b = Metadata(title: 'same', authors: ['x'], rating: 2.0);
      final engine = MetadataEngine()
        ..registerSource(_StubSource('s1', [a]))
        ..registerSource(_StubSource('s2', [b]));
      final results = await engine.find(title: 'Same');
      expect(results, hasLength(1));
      expect(results[0].rating, 2.0);
    });

    test('swallows failing source', () async {
      final engine = MetadataEngine()
        ..registerSource(_StubSource('bad', [], throws: true))
        ..registerSource(
            _StubSource('good', [Metadata(title: 'Ok', rating: 1.0)]));
      final results = await engine.find(title: 'Ok');
      expect(results, hasLength(1));
      expect(results[0].title, 'Ok');
    });

    test('fetchCover returns bytes', () async {
      final meta = Metadata(
          title: 'Book', sourceId: 'good', coverUrl: 'http://x/cover.jpg');
      final source = _StubSource('good', [],
          cover: Uint8List.fromList('JPEGDATA'.codeUnits));
      final engine = MetadataEngine()..registerSource(source);
      expect(await engine.fetchCover(meta),
          Uint8List.fromList('JPEGDATA'.codeUnits));
      expect(source.coverCalls, 1);
    });

    test('fetchCover unknown source', () async {
      final engine = MetadataEngine();
      expect(await engine.fetchCover(Metadata(sourceId: 'nope')), isNull);
    });

    test('fetchCover matches by source name', () async {
      final source = _StubSource('stub-src', [],
          name: 'Stub Source', cover: Uint8List.fromList('img'.codeUnits));
      final engine = MetadataEngine()..registerSource(source);
      final meta = Metadata(
        title: 'Book',
        coverUrl: 'http://x/cover.jpg',
        sourceId: 'book-key-1',
        sourceName: 'Stub Source',
      );
      expect(await engine.fetchCover(meta),
          Uint8List.fromList('img'.codeUnits));
      expect(source.coverCalls, 1);
    });

    test('fetchCover no match returns null', () async {
      final source = _StubSource('stub-src', [], name: 'Stub Source');
      final engine = MetadataEngine()..registerSource(source);
      final meta = Metadata(
        title: 'Book',
        coverUrl: 'http://x/cover.jpg',
        sourceId: 'other-key',
        sourceName: 'Other Source',
      );
      // Engine-level URL fallback would try a network fetch; with no client
      // injected it must fail to null, but downloadCover must not be called.
      final result = await engine.fetchCover(meta,
          client: failingClient());
      expect(result, isNull);
      expect(source.coverCalls, 0);
    });

    test('findQuery uses isbn lookup', () async {
      final source = _StubSource('stub', [], name: 'Stub');
      final engine = MetadataEngine()..registerSource(source);
      await engine.findQuery('978-0-44-101359-3');
      expect(source.isbnSearches, ['9780441013593']);
    });

    test('findQuery ranks closest title first', () async {
      final exact =
          Metadata(title: 'Dune', authors: ['Frank Herbert'], rating: 4.0, sourceId: 'a');
      final sequel = Metadata(
          title: 'Dune Messiah',
          authors: ['Frank Herbert'],
          rating: 5.0,
          sourceId: 'b');
      final unrelated =
          Metadata(title: 'Cooking', authors: ['Someone'], rating: 5.0, sourceId: 'c');
      final source = _StubSource('stub', [],
          name: 'Stub', freeTextResults: [unrelated, sequel, exact]);
      final engine = MetadataEngine()..registerSource(source);
      final results = await engine.findQuery('dune frank herbert');
      expect(results[0].sourceId, 'merged');
      expect(results.sublist(1).map((m) => m.title),
          ['Dune', 'Dune Messiah', 'Cooking']);
    });

    test('findQuery empty returns empty', () async {
      expect(await MetadataEngine().findQuery('   '), isEmpty);
    });

    test('filters non-english results', () async {
      final english = Metadata(title: 'Dune', language: 'en', sourceId: 'en');
      final french = Metadata(title: 'Le Dune', language: 'fre', sourceId: 'fr');
      final engine = MetadataEngine()
        ..registerSource(_StubSource('stub', [french, english], name: 'Stub'));
      final results = await engine.find(title: 'Dune');
      expect(results.map((m) => m.sourceId), ['en']);
    });
  });
}

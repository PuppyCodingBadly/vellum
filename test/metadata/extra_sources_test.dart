/// Tests for the additional built-in metadata sources.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vellum/metadata/sources/internet_archive.dart';
import 'package:vellum/metadata/sources/inventaire.dart';
import 'package:vellum/metadata/sources/library_of_congress.dart';

http.Client jsonClient(Object? payload, {List<http.Request>? captured}) {
  return MockClient((request) async {
    captured?.add(request);
    return http.Response(jsonEncode(payload), 200,
        headers: {'content-type': 'application/json'});
  });
}

http.Client failingClient() =>
    MockClient((request) async => throw Exception('down'));

const iaPayload = {
  'response': {
    'docs': [
      {
        'identifier': 'dune',
        'title': 'Dune',
        'creator': 'Frank Herbert',
        'date': '1965',
        'publisher': 'Chilton',
        'language': 'eng',
        'description': ['<p>Spice must flow.</p>'],
        'subject': ['Science fiction'],
        'isbn': ['0441013597', '9780441013593'],
      }
    ]
  }
};

const locPayload = {
  'results': [
    {
      'id': 'http://www.loc.gov/item/1',
      'title': 'Dune',
      'contributor': ['Herbert, Frank'],
      'date': '1965',
      'description': ['A novel.'],
      'image_url': ['https://example.com/cover.jpg#h=1'],
      'subject': ['Science fiction'],
      'language': ['eng'],
      'item': {
        'created_published': ['New York : Chilton, 1965.'],
        'language': ['eng'],
      },
    }
  ]
};

const inventaireSearch = {
  'results': [
    {'id': 'Q190192', 'uri': 'wd:Q190192', 'image': '/img/entities/hash'}
  ]
};

const inventaireEntities = {
  'entities': {
    'wd:Q190192': {
      'uri': 'wd:Q190192',
      'wdId': 'Q190192',
      'labels': {'en': 'Dune'},
      'descriptions': {'en': '1965 science fiction novel'},
      'claims': {
        'wdt:P50': ['wd:Q7934'],
        'wdt:P136': ['wd:Q1'],
        'wdt:P577': ['1965'],
        'wdt:P407': ['wd:Q1860'],
      },
    },
    'wd:Q7934': {
      'labels': {'en': 'Frank Herbert'}
    },
    'wd:Q1': {
      'labels': {'en': 'Science fiction'}
    },
    'wd:Q1860': {
      'labels': {'en': 'English'}
    },
  }
};

void main() {
  group('InternetArchive', () {
    test('mapping', () async {
      final captured = <http.Request>[];
      final results = await InternetArchive().search(
          title: 'Dune', client: jsonClient(iaPayload, captured: captured));
      expect(results, hasLength(1));
      final meta = results[0];
      expect(meta.title, 'Dune');
      expect(meta.authors, ['Frank Herbert']);
      expect(meta.isbn, '9780441013593');
      expect(meta.publisher, 'Chilton');
      expect(meta.language, 'eng');
      expect(meta.description, 'Spice must flow.');
      expect(meta.tags, ['Science fiction']);
      expect(meta.coverUrl, endsWith('/dune'));
      expect(meta.sourceId, 'internet-archive:dune');
      expect(captured.single.url.queryParameters['q'],
          contains('title:(Dune)'));
    });

    test('free text query string', () async {
      final captured = <http.Request>[];
      await InternetArchive().searchFreeText('dune herbert',
          client: jsonClient({
            'response': {'docs': []}
          }, captured: captured));
      expect(captured.single.url.queryParameters['q'],
          '(dune herbert) AND mediatype:texts AND language:(eng OR English)');
    });

    test('swallows network errors', () async {
      expect(await InternetArchive().search(title: 'x', client: failingClient()),
          isEmpty);
    });
  });

  group('LibraryOfCongress', () {
    test('mapping', () async {
      final results = await LibraryOfCongress()
          .search(title: 'Dune', client: jsonClient(locPayload));
      expect(results, hasLength(1));
      final meta = results[0];
      expect(meta.title, 'Dune');
      expect(meta.authors, ['Herbert, Frank']);
      expect(meta.publisher, 'New York : Chilton, 1965.');
      expect(meta.language, 'eng');
      expect(meta.description, 'A novel.');
      expect(meta.tags, ['Science fiction']);
      expect(meta.coverUrl, 'https://example.com/cover.jpg');
      expect(meta.sourceId, startsWith('loc:'));
    });

    test('swallows network errors', () async {
      expect(
          await LibraryOfCongress()
              .search(title: 'x', client: failingClient()),
          isEmpty);
    });
  });

  group('Inventaire', () {
    test('mapping', () async {
      final captured = <http.Request>[];
      final client = MockClient((request) async {
        captured.add(request);
        final payload = request.url.path.contains('entities')
            ? inventaireEntities
            : inventaireSearch;
        return http.Response(jsonEncode(payload), 200,
            headers: {'content-type': 'application/json'});
      });
      final results = await Inventaire().search(title: 'Dune', client: client);
      expect(results, hasLength(1));
      final meta = results[0];
      expect(meta.title, 'Dune');
      expect(meta.authors, ['Frank Herbert']);
      expect(meta.publisher, '');
      expect(meta.pubdate, '1965');
      expect(meta.language, 'English');
      expect(meta.description, '1965 science fiction novel');
      expect(meta.tags, ['Science fiction']);
      expect(meta.coverUrl, 'https://inventaire.io/img/entities/hash');
      expect(meta.sourceId, 'inventaire:Q190192');
      expect(captured.first.url.queryParameters['types'], 'works');
    });

    test('source_id uses uri tail over wdId', () async {
      const search = {
        'results': [
          {'id': 'x', 'uri': 'inv:abc123', 'image': ''}
        ]
      };
      const entities = {
        'entities': {
          'inv:abc123': {
            'uri': 'inv:abc123',
            'wdId': 'Q999',
            'labels': {'en': 'Local Book'},
            'claims': {},
          }
        }
      };
      final client = MockClient((request) async {
        final payload =
            request.url.path.contains('entities') ? entities : search;
        return http.Response(jsonEncode(payload), 200,
            headers: {'content-type': 'application/json'});
      });
      final results = await Inventaire().search(title: 'Local', client: client);
      expect(results, hasLength(1));
      expect(results[0].sourceId, 'inventaire:abc123');
    });

    test('skips non-english works', () async {
      const search = {
        'results': [
          {'uri': 'wd:Q2', 'image': ''}
        ]
      };
      const entities = {
        'entities': {
          'wd:Q2': {
            'wdId': 'Q2',
            'labels': {'fr': 'Livre'},
            'descriptions': {'fr': 'Un livre'},
            'claims': {},
          }
        }
      };
      final client = MockClient((request) async {
        final payload =
            request.url.path.contains('entities') ? entities : search;
        return http.Response(jsonEncode(payload), 200,
            headers: {'content-type': 'application/json'});
      });
      expect(await Inventaire().search(title: 'Livre', client: client),
          isEmpty);
    });
  });
}

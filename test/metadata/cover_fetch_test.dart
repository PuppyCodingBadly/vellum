/// Cover fetching for every built-in source: each one must use the shared
/// capped, idle-timeout read in universal.dart.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/metadata/sources/google_books.dart';
import 'package:vellum/metadata/sources/internet_archive.dart';
import 'package:vellum/metadata/sources/inventaire.dart';
import 'package:vellum/metadata/sources/library_of_congress.dart';
import 'package:vellum/metadata/sources/openlibrary.dart';
import 'package:vellum/metadata/universal.dart';

/// Every source that fetches covers; each must delegate to the shared reader.
final _sources = <String, MetadataSource>{
  'Google Books': GoogleBooks(),
  'Open Library': OpenLibrary(),
  'Internet Archive': InternetArchive(),
  'Inventaire': Inventaire(),
  'Library of Congress': LibraryOfCongress(),
};

final _cover = Metadata(coverUrl: 'https://example.com/cover.jpg');

http.Client _streamingClient(
  Future<http.StreamedResponse> Function(http.BaseRequest) handler,
) => _StreamClient(handler);

void main() {
  for (final MapEntry(key: name, value: source) in _sources.entries) {
    group(name, () {
      test('downloads an image through the shared reader', () async {
        final client = _streamingClient(
          (request) async => http.StreamedResponse(
            Stream.value('IMG'.codeUnits),
            200,
            headers: {'content-type': 'image/jpeg'},
          ),
        );
        expect(
          await source.downloadCover(_cover, client: client),
          Uint8List.fromList('IMG'.codeUnits),
        );
      });

      test('rejects a non-image body', () async {
        final client = _streamingClient(
          (request) async => http.StreamedResponse(
            Stream.value('<html>not an image</html>'.codeUnits),
            200,
            headers: {'content-type': 'text/html'},
          ),
        );
        expect(await source.downloadCover(_cover, client: client), isNull);
      });

      test('rejects a body over the cover cap', () async {
        final client = _streamingClient(
          (request) async => http.StreamedResponse(
            Stream.value(List<int>.filled(maxCoverBytes + 1, 1)),
            200,
            headers: {'content-type': 'image/jpeg'},
          ),
        );
        expect(await source.downloadCover(_cover, client: client), isNull);
      });

      test('fails a stalled body instead of hanging', () async {
        final body = StreamController<List<int>>();
        addTearDown(body.close);
        final client = _streamingClient(
          (request) async => http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'image/jpeg'},
          ),
        );
        expect(
          await source.downloadCover(
            _cover,
            client: client,
            timeout: const Duration(milliseconds: 20),
          ),
          isNull,
        );
      });

      test('returns null without a request when the URL is empty', () async {
        final client = _streamingClient(
          (request) async => fail('no request expected for an empty URL'),
        );
        expect(await source.downloadCover(Metadata(), client: client), isNull);
      });
    });
  }
}

/// A client with a scripted streaming response.
class _StreamClient extends http.BaseClient {
  _StreamClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vellum/store/store_download.dart';

void main() {
  group('sanitizeDownloadFileName', () {
    test('strips path-hostile characters', () {
      expect(
        sanitizeDownloadFileName('A/B\\C:D*E?F"G<H>I|J', 'epub'),
        'ABCDEFGHIJ.epub',
      );
    });

    test('keeps word chars, dots, dashes and spaces', () {
      expect(
        sanitizeDownloadFileName('My Book - Vol. 2 (final)', 'epub'),
        'My Book - Vol. 2 final.epub',
      );
    });

    test('clamps the stem to 80 characters', () {
      final name = sanitizeDownloadFileName('a' * 200, 'epub');
      expect(name, '${'a' * 80}.epub');
    });

    test('empty stem falls back to book', () {
      expect(sanitizeDownloadFileName('!!!', 'epub'), 'book.epub');
    });

    test('trims leading/trailing spaces and dots', () {
      expect(sanitizeDownloadFileName('  ..title..  ', 'epub'), 'title.epub');
    });

    test('extension is lower-cased and reduced to alnum', () {
      expect(sanitizeDownloadFileName('t', '  EPUB. '), 't.epub');
      expect(sanitizeDownloadFileName('t', 'M O B I'), 't.mobi');
    });

    test('extension takes first format of a comma list', () {
      expect(sanitizeDownloadFileName('t', 'pdf, epub'), 't.pdf');
    });

    test('invalid extension falls back to epub', () {
      expect(sanitizeDownloadFileName('t', '!!!'), 't.epub');
      expect(sanitizeDownloadFileName('t', ''), 't.epub');
    });

    test('dedups with (N) suffix against exists callback', () {
      final taken = <String>{'t.epub', 't (1).epub'};
      expect(
        sanitizeDownloadFileName('t', 'epub', exists: taken.contains),
        't (2).epub',
      );
    });

    test('no dedup when candidate is free', () {
      expect(
        sanitizeDownloadFileName('t', 'epub', exists: (_) => false),
        't.epub',
      );
    });
  });

  group('downloadToFile', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('store_download_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('streams bytes to the destination file', () async {
      // > 64 KiB so multiple chunks cross the stream.
      final body = List<int>.generate(200 * 1024, (i) => i % 251);
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://example.com/book.epub');
        return http.Response.bytes(body, 200);
      });
      final dest = '${tmp.path}/book.epub';
      final result =
          await downloadToFile('https://example.com/book.epub', dest,
              client: client);
      expect(result, dest);
      expect(await File(dest).readAsBytes(), body);
    });

    test('decodes text bodies correctly', () async {
      final client = MockClient((request) async =>
          http.Response('hello vellum', 200));
      final dest = '${tmp.path}/x.txt';
      await downloadToFile('https://example.com/x', dest, client: client);
      expect(await File(dest).readAsString(), 'hello vellum');
    });

    test('throws on non-2xx status', () async {
      final client =
          MockClient((request) async => http.Response('nope', 404));
      expect(
        () => downloadToFile('https://example.com/missing',
            '${tmp.path}/missing.epub',
            client: client),
        throwsA(isA<HttpException>()),
      );
    });

    test('creates missing parent directories', () async {
      final client =
          MockClient((request) async => http.Response.bytes([1, 2, 3], 200));
      final dest = '${tmp.path}/nested/deep/book.epub';
      await downloadToFile('https://example.com/b', dest, client: client);
      expect(await File(dest).readAsBytes(), [1, 2, 3]);
    });
  });
}

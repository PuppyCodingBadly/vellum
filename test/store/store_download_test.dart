import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vellum/store/store_download.dart';

/// A client whose response is scripted, including failures mid-stream.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

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

  group('downloadBook', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('store_download_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<File> download(
      http.Client client, {
      String title = 'book',
      String url = 'https://example.com/book.epub',
    }) => downloadBook(
      url: url,
      title: title,
      formats: 'epub',
      directory: tmp.path,
      client: client,
    );

    /// Every file under [tmp] with its relative name.
    List<String> files() => [
      for (final entry in tmp.listSync(recursive: true))
        if (entry is File) p.relative(entry.path, from: tmp.path),
    ];

    test('streams bytes to the published file and leaves no partial', () async {
      // > 64 KiB so multiple chunks cross the stream.
      final body = List<int>.generate(200 * 1024, (i) => i % 251);
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://example.com/book.epub');
        return http.Response.bytes(
          body,
          200,
          headers: {'content-type': 'application/epub+zip'},
        );
      });
      final file = await download(client);
      expect(p.basename(file.path), 'book.epub');
      expect(await file.readAsBytes(), body);
      expect(files(), ['book.epub']);
    });

    test('dedups an existing title with (N)', () async {
      File(p.join(tmp.path, 'book.epub')).writeAsStringSync('old');
      final client = MockClient(
        (request) async => http.Response.bytes([1, 2, 3], 200),
      );
      final file = await download(client);
      expect(p.basename(file.path), 'book (1).epub');
      expect(files()..sort(), ['book (1).epub', 'book.epub']);
    });

    test('throws on non-2xx status and leaves no final path', () async {
      final client = MockClient((request) async => http.Response('nope', 404));
      await expectLater(download(client), throwsA(isA<HttpException>()));
      expect(files(), isEmpty);
    });

    test('rejects a markup body instead of saving a web page', () async {
      final client = MockClient(
        (request) async => http.Response(
          '<html>error</html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(download(client), throwsA(isA<HttpException>()));
      expect(files(), isEmpty);
    });

    test('rejects a declared body over the size cap', () async {
      final client = _ScriptedClient(
        (request) async => http.StreamedResponse(
          const Stream<List<int>>.empty(),
          200,
          contentLength: maxDownloadBytes + 1,
        ),
      );
      await expectLater(download(client), throwsA(isA<HttpException>()));
      expect(files(), isEmpty);
    });

    test('removes the partial when the body fails mid-stream', () async {
      Stream<List<int>> failingBody() async* {
        yield [1, 2, 3];
        throw const SocketException('connection reset');
      }

      final client = _ScriptedClient(
        (request) async => http.StreamedResponse(failingBody(), 200),
      );
      await expectLater(download(client), throwsA(isA<SocketException>()));
      expect(files(), isEmpty);
    });

    test('concurrent downloads of one title reserve different files', () async {
      final gates = <Completer<void>>[];
      final client = _ScriptedClient((request) async {
        final gate = Completer<void>();
        gates.add(gate);
        final body = StreamController<List<int>>();
        gate.future.then((_) {
          body
            ..add([1, 2, 3])
            ..close();
        });
        return http.StreamedResponse(body.stream, 200);
      });
      final first = download(client);
      final second = download(client);
      // Wait until both reservations exist as distinct partials.
      while (gates.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(files().where((name) => name.endsWith('.part')).toSet(), {
        'book.epub.part',
        'book (1).epub.part',
      });
      for (final gate in gates) {
        gate.complete();
      }
      final published = await Future.wait([first, second]);
      expect(published.map((file) => p.basename(file.path)).toSet(), {
        'book.epub',
        'book (1).epub',
      });
      expect(files().where((name) => name.endsWith('.part')), isEmpty);
    });
  });
}

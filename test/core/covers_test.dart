import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vellum/core/covers.dart';

/// Big-endian 32-bit encoding, as PNG chunks use.
List<int> _u32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

List<int> _chunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  return [
    ..._u32(data.length),
    ...typeBytes,
    ...data,
    ..._u32(getCrc32([...typeBytes, ...data])),
  ];
}

/// A PNG that declares [width]×[height] but carries no pixel data.
///
/// Header parsing succeeds, so a pixel-budget check can reject it before a
/// decoder ever allocates the declared raster.
List<int> _pngHeaderOnly(int width, int height) => [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  ..._chunk('IHDR', [..._u32(width), ..._u32(height), 8, 6, 0, 0, 0]),
  ..._chunk('IEND', const []),
];

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-covers');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  String writeCover(String name, int w, int h) {
    final image = img.Image(width: w, height: h);
    img.fill(image, color: img.ColorRgb8(200, 30, 30));
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(img.encodePng(image));
    return path;
  }

  test('constants', () {
    expect(THUMB_MAX_WIDTH, 320);
    expect(THUMB_MAX_HEIGHT, 480);
    expect(MAX_COVER_BYTES, 25 * 1024 * 1024);
    expect(MAX_COVER_PIXELS, 80000000);
  });

  test('thumbCachePath: distinct digests per cover path', () {
    final a = thumbCachePath(tmp.path, 1, '/covers/a.png');
    final b = thumbCachePath(tmp.path, 1, '/covers/b.png');
    expect(a, isNot(b));
    expect(a, startsWith('${tmp.path}/covers/thumbs/1-'));
    expect(a, endsWith('.png'));
    // Deterministic while the cover bytes are unchanged.
    expect(thumbCachePath(tmp.path, 1, '/covers/a.png'), a);
  });

  test('1200x1800 cover thumbnailed to exactly 320x480', () {
    final cover = writeCover('big.png', 1200, 1800);
    final thumb = thumbPath(tmp.path, 7, cover);
    expect(thumb, isNot(cover));
    expect(File(thumb).existsSync(), isTrue);
    final decoded = img.decodePng(File(thumb).readAsBytesSync())!;
    expect(decoded.width, 320);
    expect(decoded.height, 480);
  });

  test('small cover is not upscaled', () {
    final cover = writeCover('small.png', 100, 150);
    final thumb = thumbPath(tmp.path, 7, cover);
    final decoded = img.decodePng(File(thumb).readAsBytesSync())!;
    expect(decoded.width, 100);
    expect(decoded.height, 150);
  });

  test('fresh thumb returned without regeneration (mtime rule)', () {
    final cover = writeCover('fresh.png', 1200, 1800);
    final first = thumbPath(tmp.path, 7, cover);
    final firstMtime = File(first).lastModifiedSync();
    // Second call must reuse the cache.
    final second = thumbPath(tmp.path, 7, cover);
    expect(second, first);
    expect(File(second).lastModifiedSync(), firstMtime);
  });

  test('overwriting a cover at the same path yields a new thumb path', () {
    final cover = writeCover('overwrite.png', 1200, 1800);
    final first = thumbPath(tmp.path, 7, cover);
    final firstBytes = File(first).readAsBytesSync();

    final updated = img.Image(width: 1200, height: 1800);
    img.fill(updated, color: img.ColorRgb8(30, 30, 200));
    File(cover).writeAsBytesSync(img.encodePng(updated));
    File(cover).setLastModifiedSync(
      File(cover).lastModifiedSync().add(const Duration(seconds: 5)),
    );

    final second = thumbPath(tmp.path, 7, cover);
    expect(
      second,
      isNot(first),
      reason: 'a changed mtime/size must change the cache key',
    );
    expect(File(second).existsSync(), isTrue);
    expect(File(second).readAsBytesSync(), isNot(firstBytes));
  });

  test('oversized raster rejected from its header without decoding', () {
    final cover = '${tmp.path}/huge.png';
    File(cover).writeAsBytesSync(_pngHeaderOnly(10000, 10000));
    final thumb = thumbPath(tmp.path, 7, cover);
    expect(thumb, cover);
    // Rejection happened before a thumbnail file was even created.
    expect(Directory('${tmp.path}/covers/thumbs').existsSync(), isFalse);
  });

  test('zero-byte and partial thumbs are regenerated, not served', () {
    final cover = writeCover('partial.png', 1200, 1800);
    final thumb = thumbCachePath(tmp.path, 7, cover);
    File(thumb).parent.createSync(recursive: true);

    final full = img.encodePng(img.Image(width: 40, height: 60));
    File(thumb).writeAsBytesSync(full.sublist(0, full.length - 6));

    expect(thumbPath(tmp.path, 7, cover), thumb);
    expect(img.decodePng(File(thumb).readAsBytesSync()), isNotNull);

    File(thumb).writeAsBytesSync(const []);
    expect(thumbPath(tmp.path, 7, cover), thumb);
    expect(File(thumb).lengthSync(), greaterThan(0));
  });

  test('missing or garbage cover falls back to input path', () {
    expect(
      thumbPath(tmp.path, 1, '${tmp.path}/nope.png'),
      '${tmp.path}/nope.png',
    );
    final garbage = '${tmp.path}/garbage.png';
    File(garbage).writeAsBytesSync([1, 2, 3, 4, 5]);
    expect(thumbPath(tmp.path, 1, garbage), garbage);
    expect(thumbPath(tmp.path, 1, ''), '');
  });

  group('replaceCover', () {
    Directory coversDir() => Directory('${tmp.path}/covers');

    List<String> coverNames() =>
        coversDir().listSync().map((e) => p.basename(e.path)).toList()..sort();

    Uint8List pngBytes() => img.encodePng(img.Image(width: 4, height: 6));

    test('keeps a known container bytes and extension', () async {
      // A JPEG header is enough: known containers are stored as fetched.
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x20]);
      String? saved;
      await replaceCover(
        dataDir: tmp.path,
        bookId: 3,
        bytes: jpeg,
        saveBook: (coverPath) => saved = coverPath,
      );

      expect(saved, '${coversDir().path}/3.jpg');
      expect(File(saved!).readAsBytesSync(), jpeg);
      expect(coverNames(), ['3.jpg'], reason: 'no temp file remains');
    });

    test('a failing book save leaves the previous cover untouched', () async {
      coversDir().createSync(recursive: true);
      final oldBytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x33, 0x44];
      final old = File('${coversDir().path}/5.jpg')..writeAsBytesSync(oldBytes);
      String? offered;

      await expectLater(
        replaceCover(
          dataDir: tmp.path,
          bookId: 5,
          bytes: pngBytes(),
          saveBook: (coverPath) {
            offered = coverPath;
            throw StateError('library is gone');
          },
        ),
        throwsStateError,
      );

      expect(offered, '${coversDir().path}/5.png');
      expect(old.readAsBytesSync(), oldBytes);
      expect(coverNames(), [
        '5.jpg',
      ], reason: 'no new cover and no temp file after a failed save');
    });

    test(
      'deletes the cover of the previous format but never a generated one',
      () async {
        coversDir().createSync(recursive: true);
        final previous = File('${coversDir().path}/8.jpg')
          ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0x01]);
        final generated = File('${coversDir().path}/generated-8.png')
          ..writeAsBytesSync([9, 9, 9]);

        String? saved;
        await replaceCover(
          dataDir: tmp.path,
          bookId: 8,
          bytes: pngBytes(),
          saveBook: (coverPath) => saved = coverPath,
        );

        expect(saved, '${coversDir().path}/8.png');
        expect(previous.existsSync(), isFalse);
        expect(generated.readAsBytesSync(), [9, 9, 9]);
        expect(coverNames(), ['8.png', 'generated-8.png']);
      },
    );

    test('an unknown container is stored as PNG', () async {
      final image = img.Image(width: 3, height: 5);
      img.fill(image, color: img.ColorRgb8(10, 20, 30));
      final bmp = img.encodeBmp(image);

      String? saved;
      await replaceCover(
        dataDir: tmp.path,
        bookId: 2,
        bytes: bmp,
        saveBook: (coverPath) => saved = coverPath,
      );

      expect(saved, endsWith('/2.png'));
      final stored = img.decodePng(File(saved!).readAsBytesSync())!;
      expect(stored.width, 3);
      expect(stored.height, 5);
    });

    test('undecodable bytes are rejected before anything is written', () async {
      var saved = false;
      final write = replaceCover(
        dataDir: tmp.path,
        bookId: 4,
        bytes: Uint8List.fromList('<html>not a cover</html>'.codeUnits),
        saveBook: (_) => saved = true,
      );
      await expectLater(write, throwsA(isA<CoverWriteException>()));

      expect(saved, isFalse);
      expect(coversDir().existsSync(), isFalse);
    });
  });
}

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:vellum/core/covers.dart';

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
    // Deterministic.
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

  test('stale thumb regenerated when cover is newer', () {
    final cover = writeCover('stale.png', 1200, 1800);
    final first = thumbPath(tmp.path, 7, cover);
    final firstMtime = File(first).lastModifiedSync();
    final firstBytes = File(first).readAsBytesSync();
    // Make the cover newer than the thumb AND change its content so
    // regeneration is provable independent of mtime precision.
    final updated = img.Image(width: 1200, height: 1800);
    img.fill(updated, color: img.ColorRgb8(30, 30, 200));
    File(cover).writeAsBytesSync(img.encodePng(updated));
    File(cover)
        .setLastModifiedSync(firstMtime.add(const Duration(seconds: 5)));
    final second = thumbPath(tmp.path, 7, cover);
    expect(second, first); // same path, regenerated
    expect(File(second).readAsBytesSync(), isNot(firstBytes));
  });

  test('missing or garbage cover falls back to input path', () {
    expect(thumbPath(tmp.path, 1, '${tmp.path}/nope.png'),
        '${tmp.path}/nope.png');
    final garbage = '${tmp.path}/garbage.png';
    File(garbage).writeAsBytesSync([1, 2, 3, 4, 5]);
    expect(thumbPath(tmp.path, 1, garbage), garbage);
    expect(thumbPath(tmp.path, 1, ''), '');
  });
}

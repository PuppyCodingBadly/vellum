import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vellum/core/cover_generator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('renders a 2:3 PNG in the chosen style', () async {
    final png = await generateCoverPng(
      title: 'Dune',
      author: 'Frank Herbert',
      publisher: 'Chilton',
      width: 120,
      height: 180,
    );
    final image = img.decodePng(png)!;
    expect(image.width, 120);
    expect(image.height, 180);
    // The stock fills the canvas edge to edge.
    final corner = image.getPixel(0, 0);
    expect([corner.r, corner.g, corner.b], [246, 242, 234]);
  });

  test('styles use distinct stocks', () async {
    Future<img.Image> render(CoverStyle style) async => img.decodePng(
          await generateCoverPng(
            title: 'Dune',
            author: 'Frank Herbert',
            style: style,
            width: 90,
            height: 135,
          ),
        )!;

    final paper = await render(CoverStyle.paper);
    final ink = await render(CoverStyle.ink);
    final accent = await render(CoverStyle.accent);
    final paperPixel = paper.getPixel(1, 1);
    final inkPixel = ink.getPixel(1, 1);
    final accentPixel = accent.getPixel(1, 1);

    // Exact stocks: warm paper, ink, and copper.
    expect([paperPixel.r, paperPixel.g, paperPixel.b], [246, 242, 234]);
    expect([inkPixel.r, inkPixel.g, inkPixel.b], [20, 18, 15]);
    expect([accentPixel.r, accentPixel.g, accentPixel.b], [184, 116, 51]);
  });

  test('writes next to downloaded covers without overwriting them', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-generated-cover');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final downloaded = File('${tmp.path}/covers/7.jpg')
      ..createSync(recursive: true)
      ..writeAsStringSync('downloaded');

    final png = await generateCoverPng(title: 'Generated', width: 60, height: 90);
    final path = await writeGeneratedCover(
      dataDir: tmp.path,
      bookId: 7,
      png: png,
    );

    expect(path, endsWith('/covers/generated-7.png'));
    expect(File(path).readAsBytesSync(), png);
    expect(downloaded.readAsStringSync(), 'downloaded');
  });
}

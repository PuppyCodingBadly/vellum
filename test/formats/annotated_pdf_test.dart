/// Tests for vellum formats/annotated_pdf.dart.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:test/test.dart';
import 'package:vellum/core/ink.dart';
import 'package:vellum/formats/annotated_pdf.dart';

/// Build a minimal valid multi-page PDF with a real xref table.
///
/// Mirrors the fixture in `pdf_book_test.dart`, so the exporter is tested
/// against the same kind of PDFium-readable input as the reader.
String _makePdf(
  String path, [
  List<String> texts = const ['Hello page one', 'Hello page two'],
  String mediaBox = '0 0 612 792',
]) {
  final objects = <List<int>>[];
  objects.add('<< /Type /Catalog /Pages 2 0 R >>'.codeUnits);
  final kids = [
    for (var i = 0; i < texts.length; i++) '${3 + i * 2} 0 R',
  ].join(' ');
  objects.add(
    '<< /Type /Pages /Kids [$kids] /Count ${texts.length} >>'.codeUnits,
  );
  final fontObj = 3 + texts.length * 2;
  for (var i = 0; i < texts.length; i++) {
    final content = 'BT /F1 24 Tf 72 700 Td (${texts[i]}) Tj ET';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [$mediaBox] '
              '/Resources << /Font << /F1 $fontObj 0 R >> >> '
              '/Contents ${4 + i * 2} 0 R >>'
          .codeUnits,
    );
    objects.add([
      ...'<< /Length ${content.length} >>\nstream\n'.codeUnits,
      ...content.codeUnits,
      ...'\nendstream'.codeUnits,
    ]);
  }
  objects.add(
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'.codeUnits,
  );

  final out = BytesBuilder()..add('%PDF-1.4\n'.codeUnits);
  final offsets = <int>[0];
  for (var num = 1; num <= objects.length; num++) {
    offsets.add(out.length);
    out.add('$num 0 obj\n'.codeUnits);
    out.add(objects[num - 1]);
    out.add('\nendobj\n'.codeUnits);
  }
  final xrefStart = out.length;
  final size = objects.length + 1;
  out.add('xref\n0 $size\n'.codeUnits);
  out.add('0000000000 65535 f \n'.codeUnits);
  for (final off in offsets.sublist(1)) {
    out.add('${off.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add('trailer\n<< /Size $size /Root 1 0 R >>\n'.codeUnits);
  out.add('startxref\n$xrefStart\n%%EOF\n'.codeUnits);
  File(path).writeAsBytesSync(out.toBytes());
  return path;
}

InkStroke _stroke({
  required int page,
  required double width,
  required int color,
  required List<double> points,
}) => InkStroke(
  anchor: InkAnchor(
    kind: InkAnchorKind.page,
    chapter: page,
    rect: const Rect.fromLTWH(0, 0, 612, 792),
  ),
  color: color,
  width: width,
  points: Float32List.fromList(points),
);

bool _has(Uint8List bytes, String needle) =>
    latin1.decode(bytes).contains(needle);

int _pageObjects(Uint8List bytes) =>
    RegExp(r'/Type/Page\b').allMatches(latin1.decode(bytes)).length;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('annotated-pdf-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('keeps the page count and overlays ink on the annotated page', () async {
    final source = _makePdf('${tmp.path}/book.pdf');
    final plain = await buildAnnotatedPdf(
      sourcePath: source,
      strokesByPage: const <int, List<InkStroke>>{},
    );
    final annotated = await buildAnnotatedPdf(
      sourcePath: source,
      strokesByPage: {
        0: [
          _stroke(
            page: 0,
            width: 4,
            color: 0xCCFF0000,
            points: [
              0.1, 0.1, 0.4, //
              0.5, 0.5, 0.8,
              0.9, 0.2, 1.0,
            ],
          ),
        ],
      },
    );

    expect(latin1.decode(plain).substring(0, 5), '%PDF-');
    expect(latin1.decode(annotated).substring(0, 5), '%PDF-');
    // Both pages survive, including the one without strokes.
    expect(RegExp(r'/Count\s+2\b').hasMatch(latin1.decode(annotated)), isTrue);
    expect(_pageObjects(annotated), 2);

    // Each page keeps its raster; the ink adds vector graphics on top.
    expect(_has(annotated, '/Subtype/Image'), isTrue);
    expect(_has(plain, '/ExtGState'), isFalse);
    expect(_has(annotated, '/ExtGState'), isTrue);
    expect(annotated.length, greaterThan(plain.length));
  });

  test('a page that fails to render aborts and names the page', () async {
    // 20000×20000 points is far above the raster budget, so PDFium refuses
    // page 1 before allocating; the export must not drop it silently.
    final source = _makePdf('${tmp.path}/huge.pdf', const [
      'one',
      'two',
    ], '0 0 20000 20000');
    await expectLater(
      buildAnnotatedPdf(
        sourcePath: source,
        strokesByPage: const <int, List<InkStroke>>{},
      ),
      throwsA(
        isA<AnnotatedPdfException>()
            .having((error) => error.pageIndex, 'pageIndex', 0)
            .having((error) => error.message, 'message', contains('page 1')),
      ),
    );
  });

  test('an unreadable source throws without producing bytes', () async {
    await expectLater(
      buildAnnotatedPdf(
        sourcePath: '${tmp.path}/missing.pdf',
        strokesByPage: const <int, List<InkStroke>>{},
      ),
      throwsA(isA<AnnotatedPdfException>()),
    );
  });

  test('rejects an invalid render scale before touching the file', () async {
    await expectLater(
      buildAnnotatedPdf(
        sourcePath: '${tmp.path}/missing.pdf',
        strokesByPage: const <int, List<InkStroke>>{},
        renderScale: 0,
      ),
      throwsA(isA<AnnotatedPdfException>()),
    );
  });
}

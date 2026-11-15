/// Tests for vellum formats/pdf_book.dart (mirrors tests/test_pdfbook.py).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vellum/formats/ocr.dart';
import 'package:vellum/formats/pdf_book.dart';
import 'package:vellum/formats/pdf_reflow.dart';

const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// An engine that recognizes nothing, for pages expected to stay images.
class _EmptyOcr implements OcrEngine {
  const _EmptyOcr();

  @override
  Future<OcrLayout> recognize(
    Uint8List png, {
    required int imageWidth,
    required int imageHeight,
    required double dpi,
  }) async => OcrLayout(
    words: const <OcrWord>[],
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
}

/// An engine that returns fixed words, standing in for Tesseract.
class _FixedOcr implements OcrEngine {
  _FixedOcr(this.words);

  final List<OcrWord> words;

  @override
  Future<OcrLayout> recognize(
    Uint8List png, {
    required int imageWidth,
    required int imageHeight,
    required double dpi,
  }) async =>
      OcrLayout(words: words, imageWidth: imageWidth, imageHeight: imageHeight);
}

/// An engine without a usable installation.
class _ThrowingOcr implements OcrEngine {
  const _ThrowingOcr();

  @override
  Future<OcrLayout> recognize(
    Uint8List png, {
    required int imageWidth,
    required int imageHeight,
    required double dpi,
  }) async => throw const OcrException(
    'OCR is unavailable: install tesseract-ocr to read scanned pages.',
  );
}

OcrWord _ocrWord(String text, int left, int top, int width, int height) =>
    OcrWord(
      text: text,
      left: left,
      top: top,
      width: width,
      height: height,
      block: 1,
      paragraph: 1,
      line: 1,
      confidence: 95,
    );

/// Build a minimal valid multi-page PDF with a real xref table.
String _makePdf(
  String path, [
  List<String> texts = const ['Hello page one', 'Hello page two'],
  String mediaBox = '0 0 612 792',
  List<String>? streams,
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
    final content = streams?[i] ?? 'BT /F1 24 Tf 72 700 Td (${texts[i]}) Tj ET';
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

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pdf-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('page count', () async {
    final pdf = PdfBook(_makePdf('${tmp.path}/book.pdf'));
    await pdf.renderPage(0); // forces the document open
    expect(pdf.pageCount(), 2);
  });

  test('render pages return distinct PNGs', () async {
    final pdf = PdfBook(_makePdf('${tmp.path}/book.pdf'));
    final page0 = await pdf.renderPage(0);
    final page1 = await pdf.renderPage(1);
    expect(Uint8List.fromList(page0.sublist(0, 8)), _pngMagic);
    expect(Uint8List.fromList(page1.sublist(0, 8)), _pngMagic);
    expect(page0, isNot(equals(page1)));
  });

  test('titleAt fallback', () async {
    final pdf = PdfBook(_makePdf('${tmp.path}/book.pdf'));
    await pdf.renderPage(0);
    expect(pdf.titleAt(0), isNotEmpty);
    expect(
      pdf.titleAt(1) != pdf.titleAt(0) || pdf.titleAt(0) == 'Page 1',
      isTrue,
    );
  });

  test('reflow reads the PDF text layer without OCR', () async {
    final pdf = PdfBook(
      _makePdf('${tmp.path}/reflow.pdf', [
        'Hello reflow page with several words',
      ]),
    );
    try {
      final page = await pdf.reflowPage(0);
      expect(page.hasText, isTrue);
      expect(page.atlasPng, isNotNull);
      final text = page.blocks
          .whereType<PdfReflowParagraph>()
          .map((paragraph) => paragraph.text)
          .join(' ');
      expect(text, contains('Hello reflow page'));
      final words = page.blocks
          .whereType<PdfReflowParagraph>()
          .expand((paragraph) => paragraph.lines)
          .expand((line) => line.words)
          .toList();
      expect(words, isNotEmpty);
      expect(words.first.atlasWidth, greaterThan(0));
    } finally {
      pdf.close();
    }
  });

  test('a scanned page falls back when OCR finds nothing', () async {
    // A PDF with no content stream still has a page but no text layer.
    final pdf = PdfBook(
      _makePdf('${tmp.path}/blank.pdf', ['']),
      ocr: const _EmptyOcr(),
    );
    try {
      final page = await pdf.reflowPage(0);
      expect(page.hasText, isFalse);
      expect(page.atlasPng, isNull);
      expect(page.message, contains('OCR found no text'));
    } finally {
      pdf.close();
    }
  });

  test('a page without a text layer reflows from OCR word boxes', () async {
    // Two filled rectangles stand in for recognized words; no text objects.
    final pdf = PdfBook(
      _makePdf(
        '${tmp.path}/scan.pdf',
        [''],
        '0 0 612 792',
        ['0.1 0.1 0.1 rg 72 700 100 20 re f 180 700 60 20 re f'],
      ),
      ocr: _FixedOcr(<OcrWord>[
        _ocrWord('Scanned', 216, 216, 300, 60),
        _ocrWord('words', 540, 216, 180, 60),
      ]),
    );
    try {
      final page = await pdf.reflowPage(0);
      expect(page.hasText, isTrue);
      expect(page.usedOcr, isTrue);
      expect(page.atlasPng, isNotNull);
      final paragraphs = page.blocks.whereType<PdfReflowParagraph>().toList();
      expect(paragraphs.single.text, 'Scanned words');
      expect(paragraphs.single.lines.single.words, hasLength(2));
      expect(
        paragraphs.single.lines.single.words.every(
          (word) => word.atlasWidth > 0,
        ),
        isTrue,
      );
    } finally {
      pdf.close();
    }
  });

  test('unavailable OCR keeps the page image and explains why', () async {
    final pdf = PdfBook(
      _makePdf('${tmp.path}/scan.pdf', ['']),
      ocr: const _ThrowingOcr(),
    );
    try {
      final page = await pdf.reflowPage(0);
      expect(page.hasText, isFalse);
      expect(page.message, contains('install tesseract-ocr'));
    } finally {
      pdf.close();
    }
  });

  test('garbage file throws FormatException', () {
    final bad = File('${tmp.path}/garbage.pdf')
      ..writeAsBytesSync('this is not a pdf at all'.codeUnits);
    expect(() => PdfBook(bad.path), throwsFormatException);
  });

  test('zero-page PDF throws FormatException', () {
    expect(
      () => PdfBook(_makePdf('${tmp.path}/empty.pdf', [])),
      throwsFormatException,
    );
  });

  test('close is idempotent', () {
    final pdf = PdfBook(_makePdf('${tmp.path}/book.pdf'));
    pdf.close();
    expect(() => pdf.close(), returnsNormally); // safe to call twice
  });

  test('closed book rejects use instead of touching native handles', () {
    final pdf = PdfBook(_makePdf('${tmp.path}/book.pdf'));
    pdf.close();

    expect(() => pdf.pageCount(), throwsStateError);
    expect(() => pdf.titleAt(0), throwsStateError);
    expect(() => pdf.renderPage(0), throwsStateError);
  });

  test('rejects rasters above the pixel budget before allocating', () {
    // 20000×20000 = 400 MP, far above the budget.
    expect(
      () => PdfBook.rasterSize(20000, 20000, 1),
      throwsA(isA<PdfRenderException>()),
    );
    // A sane page at an absurd zoom also fails (595×842 → 11900×16840 px).
    expect(
      () => PdfBook.rasterSize(595, 842, 20.0),
      throwsA(isA<PdfRenderException>()),
    );
    expect(PdfBook.rasterSize(595, 842, defaultScale), (
      width: 1041,
      height: 1474,
    ));
    expect(PdfBook.rasterSize(0, 0, 1), (width: 1, height: 1));
  });

  test('the render budget covers every copy the encoder holds', () {
    // A render holds PDFium's bitmap, the RGBA copy and the encoder buffers at
    // once, so the cap follows a byte budget rather than bitmap pixels alone.
    expect(
      PdfBook.maxRasterPixels,
      PdfBook.maxRasterBytes ~/ PdfBook.bytesPerRasterPixel,
    );
    // 8000×8000 sits exactly on the 64 MP budget; one row more does not.
    expect(PdfBook.rasterSize(8000, 8000, 1), (width: 8000, height: 8000));
    expect(
      () => PdfBook.rasterSize(8000, 8001, 1),
      throwsA(isA<PdfRenderException>()),
    );
  });

  test('no code destroys process-global PDFium', () {
    // The library cache is a static, so it is isolate-local, while
    // FPDF_DestroyLibrary is process-global: a worker calling it breaks the
    // isolate that still holds cached documents.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('FPDF_DestroyLibrary') ||
          source.contains('shutdownLibrary')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('huge MediaBox render fails with a typed error, no allocation', () {
    final pdf = PdfBook(
      _makePdf('${tmp.path}/huge.pdf', const ['x'], '0 0 20000 20000'),
    );

    expect(
      pdf.renderPage(0),
      throwsA(
        isA<PdfRenderException>().having(
          (error) => error.message,
          'message',
          contains('too large'),
        ),
      ),
    );
    pdf.close();
  });
}

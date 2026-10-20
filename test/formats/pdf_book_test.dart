/// Tests for vellum formats/pdf_book.dart (mirrors tests/test_pdfbook.py).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vellum/formats/pdf_book.dart';

const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Build a minimal valid multi-page PDF with a real xref table.
String _makePdf(String path, [List<String> texts = const ['Hello page one', 'Hello page two']]) {
  final objects = <List<int>>[];
  objects.add('<< /Type /Catalog /Pages 2 0 R >>'.codeUnits);
  final kids = [for (var i = 0; i < texts.length; i++) '${3 + i * 2} 0 R'].join(' ');
  objects.add('<< /Type /Pages /Kids [$kids] /Count ${texts.length} >>'.codeUnits);
  final fontObj = 3 + texts.length * 2;
  for (var i = 0; i < texts.length; i++) {
    final content = 'BT /F1 24 Tf 72 700 Td (${texts[i]}) Tj ET';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
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
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'.codeUnits);

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
    expect(pdf.titleAt(1) != pdf.titleAt(0) || pdf.titleAt(0) == 'Page 1',
        isTrue);
  });

  test('garbage file throws FormatException', () {
    final bad = File('${tmp.path}/garbage.pdf')
      ..writeAsBytesSync('this is not a pdf at all'.codeUnits);
    expect(() => PdfBook(bad.path), throwsFormatException);
  });
}

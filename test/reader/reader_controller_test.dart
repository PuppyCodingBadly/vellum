import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/formats/pdf_reflow.dart';
import 'package:vellum/reader/reader_controller.dart';
import 'package:vellum/stats/reading_stats.dart';

/// EPUB whose second spine chapter is declared in the manifest but missing
/// from the archive, so loading chapter 2 fails.
List<int> _epubWithBrokenSecondChapter() {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string(
        'OEBPS/ch1.xhtml', '<html><body><p>first chapter</p></body></html>'));
  return ZipEncoder().encode(archive);
}

String _pdfWithText(String path) {
  const text = 'PDF reflow keeps the original words';
  const content = 'BT /F1 18 Tf 72 700 Td ($text) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = BytesBuilder()..add('%PDF-1.4\n'.codeUnits);
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.add('${i + 1} 0 obj\n'.codeUnits);
    out.add(objects[i].codeUnits);
    out.add('\nendobj\n'.codeUnits);
  }
  final xref = out.length;
  final size = objects.length + 1;
  out.add('xref\n0 $size\n'.codeUnits);
  out.add('0000000000 65535 f \n'.codeUnits);
  for (final offset in offsets.sublist(1)) {
    out.add('${offset.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add(
    'trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'
        .codeUnits,
  );
  File(path).writeAsBytesSync(out.toBytes());
  return path;
}

void main() {
  test('reader recovers from a per-chapter load failure', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-test');
    try {
      final bookFile = File('${tmp.path}/broken.epub')
        ..writeAsBytesSync(_epubWithBrokenSecondChapter());
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.hasError, isFalse);
        expect(controller.document, isNotNull);

        controller.next();
        expect(controller.hasError, isTrue);
        expect(controller.document, isNull);

        // Navigating to a healthy chapter clears the error and restores
        // the document.
        controller.previous();
        expect(controller.hasError, isFalse);
        expect(controller.document, isNotNull);
        expect(controller.document!.plainText, contains('first chapter'));
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('highlight quote truncates on rune boundaries', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-test');
    try {
      final bookFile = File('${tmp.path}/book.epub')
        ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
      final library = Library('${tmp.path}/library.db');
      final id = library.addBook(
          Book(title: 't', path: bookFile.path, formats: ['epub']));
      final controller = ReaderController(
        book: Book(id: id, title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        // 199 ASCII chars + one astral emoji = 201 UTF-16 code units.
        final text = 'a' * 199 + '\u{1F600}';
        final ok = await controller.addHighlight(
          start: 0,
          end: 1,
          color: 'yellow',
          text: text,
        );
        expect(ok, isTrue);
        final quote = controller.highlights.single.quote;
        expect(quote.runes.length, lessThanOrEqualTo(200));
        // No unpaired surrogate was stored: JSON round-trips intact.
        expect(jsonDecode(jsonEncode({'q': quote})),
            <String, Object?>{'q': quote});
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('PDF page renders through the worker and disposes cleanly', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-pdf');
    try {
      final file = File('${tmp.path}/ok.pdf')
        ..writeAsBytesSync(_pdfBytes('0 0 300 400'));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 'p', path: file.path, formats: ['pdf']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.hasError, isFalse);
        expect(controller.items, hasLength(1));

        await _waitUntil(() => controller.pdfPageBytes != null);
        final bytes = controller.pdfPageBytes;
        expect(bytes, isNotNull);
        expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        expect(controller.pdfRenderError, isNull);
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('oversized PDF page reports a render error instead of crashing',
      () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-pdf');
    try {
      final file = File('${tmp.path}/huge.pdf')
        ..writeAsBytesSync(_pdfBytes('0 0 20000 20000'));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 'p', path: file.path, formats: ['pdf']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.hasError, isFalse);

        await _waitUntil(() => controller.pdfRenderError != null);
        expect(controller.pdfPageBytes, isNull);
        expect(controller.pdfRenderError, contains('too large'));
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('PDF reflow travels through the worker isolate and caches a page',
      () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-pdf-reflow-');
    try {
      final bookFile = File(_pdfWithText('${tmp.path}/reflow.pdf'));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(
          title: 'Reflow',
          path: bookFile.path,
          formats: const ['pdf'],
        ),
        library: library,
        stats: ReadingStatsTracker(library),
        pdfReflow: true,
      );
      try {
        await controller.load();
        expect(controller.isPdf, isTrue);
        for (var i = 0; i < 120 && controller.pdfReflowPage == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final page = controller.pdfReflowPage;
        expect(page, isNotNull);
        expect(page!.hasText, isTrue);
        expect(page.atlasPng, isNotNull);
        final text = page.blocks
            .whereType<PdfReflowParagraph>()
            .map((paragraph) => paragraph.text)
            .join(' ');
        expect(text, contains('PDF reflow keeps'));
        expect(controller.pdfReflowLoading, isFalse);
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Minimal single-page PDF with the given MediaBox and no page content.
Uint8List _pdfBytes(String mediaBox) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [$mediaBox] >>',
  ];
  final out = BytesBuilder()..add('%PDF-1.4\n'.codeUnits);
  final offsets = <int>[0];
  for (var num = 1; num <= objects.length; num++) {
    offsets.add(out.length);
    out.add('$num 0 obj\n'.codeUnits);
    out.add(objects[num - 1].codeUnits);
    out.add('\nendobj\n'.codeUnits);
  }
  final xrefStart = out.length;
  final size = objects.length + 1;
  out.add('xref\n0 $size\n'.codeUnits);
  out.add('0000000000 65535 f \n'.codeUnits);
  for (final offset in offsets.sublist(1)) {
    out.add('${offset.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add('trailer\n<< /Size $size /Root 1 0 R >>\n'.codeUnits);
  out.add('startxref\n$xrefStart\n%%EOF\n'.codeUnits);
  return out.toBytes();
}

String _singleChapterEpub() {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string(
        'OEBPS/ch1.xhtml', '<html><body><p>hello world</p></body></html>'));
  return base64Encode(ZipEncoder().encode(archive));
}

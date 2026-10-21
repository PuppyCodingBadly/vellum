import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
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

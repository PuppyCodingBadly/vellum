import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/ink.dart';
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
    ..addFile(
      ArchiveFile.string(
        'OEBPS/ch1.xhtml',
        '<html><body><p>first chapter</p></body></html>',
      ),
    );
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
        Book(title: 't', path: bookFile.path, formats: ['epub']),
      );
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
        expect(jsonDecode(jsonEncode({'q': quote})), <String, Object?>{
          'q': quote,
        });
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('scroll position moves the saved progress', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-progress');
    try {
      final bookFile = File('${tmp.path}/book.epub')
        ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
      final library = Library('${tmp.path}/library.db');
      final id = library.addBook(
        Book(title: 't', path: bookFile.path, formats: ['epub']),
      );
      final controller = ReaderController(
        book: Book(id: id, title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.progress, 0.0);

        controller.reportScroll(0.5);
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        expect(controller.progress, closeTo(0.5, 1e-9));
        expect(library.getBook(id)!.progress, closeTo(0.5, 1e-9));
        expect(library.getReadingPosition(id), startsWith('epub:0:0.5000'));
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

  test(
    'oversized PDF page reports a render error instead of crashing',
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
    },
  );

  test(
    'PDF reflow travels through the worker isolate and caches a page',
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
    },
  );

  test('PDF worker restarts after its isolate exits', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-pdf');
    try {
      final file = File('${tmp.path}/multi.pdf')
        ..writeAsBytesSync(_pdfPages(4));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 'p', path: file.path, formats: ['pdf']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.items, hasLength(4));

        // Kill the worker while the first render is still in flight.
        await _waitUntil(() => controller.debugPdfWorkerRunning);
        controller.debugKillPdfWorker();
        await _waitUntil(() => !controller.debugPdfWorkerRunning);
        await _waitUntil(() => !controller.pdfPageLoading);
        expect(
          controller.pdfPageBytes != null || controller.pdfRenderError != null,
          isTrue,
          reason: 'an exited worker must settle its in-flight request',
        );

        // The next request starts a new worker instead of hanging.
        for (final target in <int>[3, 2, 3, 2]) {
          controller.goTo(target);
          await _waitUntil(() => !controller.pdfPageLoading);
          if (controller.pdfPageBytes != null) break;
        }
        expect(controller.pdfPageBytes, isNotNull);
        expect(controller.pdfRenderError, isNull);
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('PDF progress reaches 1.0 on the last page', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-pdf');
    try {
      final file = File('${tmp.path}/ten.pdf')..writeAsBytesSync(_pdfPages(10));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 'p', path: file.path, formats: ['pdf']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        controller.goTo(9);
        expect(controller.index, 9);
        expect(controller.progress, 1.0);
        // The locator format stays page-index based.
        expect(controller.locator, 'pdf:9:0.0000');
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('setFontScale re-arms the current scroll fraction', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-scale');
    try {
      final bookFile = File('${tmp.path}/book.epub')
        ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
      final library = Library('${tmp.path}/library.db');
      final controller = ReaderController(
        book: Book(title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        controller.reportScroll(0.4);
        controller.setFontScale(1.3);
        expect(controller.takePendingScrollFraction(), closeTo(0.4, 1e-9));
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test(
    'highlights on missing chapters are dropped and never jumped to',
    () async {
      final tmp = Directory.systemTemp.createTempSync('vellum-reader-mark');
      try {
        final bookFile = File('${tmp.path}/book.epub')
          ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
        final library = Library('${tmp.path}/library.db');
        final id = library.addBook(
          Book(title: 't', path: bookFile.path, formats: ['epub']),
        );
        final stale = library.addHighlight(
          id,
          jsonEncode(<String, Object?>{'chapter': 5, 'start': 0, 'end': 4}),
          'yellow',
          'gone',
        );
        final valid = library.addHighlight(
          id,
          jsonEncode(<String, Object?>{
            'chapter': 0,
            'start': 0,
            'end': 5,
            'quote': 'hello',
          }),
          'yellow',
          'hello',
        );
        final controller = ReaderController(
          book: Book(
            id: id,
            title: 't',
            path: bookFile.path,
            formats: ['epub'],
          ),
          library: library,
          stats: ReadingStatsTracker(library),
        );
        try {
          await controller.load();
          expect(controller.highlights.map((h) => h.chapter), <int>[0]);

          expect(controller.goToHighlight(stale), isFalse);
          expect(controller.takePendingJumpOffset(), isNull);
          expect(controller.goToHighlight(valid), isTrue);
          expect(controller.takePendingJumpOffset(), 0);
        } finally {
          controller.dispose();
          library.close();
        }
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
  );

  test('each reader ends the session of its own book', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-session');
    final library = Library('${tmp.path}/library.db');
    try {
      final epub = base64Decode(_singleChapterEpub());
      final fileA = File('${tmp.path}/a.epub')..writeAsBytesSync(epub);
      final fileB = File('${tmp.path}/b.epub')..writeAsBytesSync(epub);
      final idA = library.addBook(
        Book(title: 'a', path: fileA.path, formats: ['epub']),
      );
      final idB = library.addBook(
        Book(title: 'b', path: fileB.path, formats: ['epub']),
      );
      final stats = ReadingStatsTracker(library);
      final readerA = ReaderController(
        book: Book(id: idA, title: 'a', path: fileA.path, formats: ['epub']),
        library: library,
        stats: stats,
      );
      final readerB = ReaderController(
        book: Book(id: idB, title: 'b', path: fileB.path, formats: ['epub']),
        library: library,
        stats: stats,
      );
      await readerA.load();
      await readerB.load();

      // Closing A first must end A's session, not B's.
      readerA.dispose();
      expect(stats.activeElapsed(idA), isNull);
      expect(stats.activeElapsed(idB), isNotNull);
      expect(stats.recentSessions(10).single['book_id'], idA);

      readerB.dispose();
      expect(stats.activeElapsed(idB), isNull);
      expect(stats.recentSessions(10).map((s) => s['book_id']).toList(), <int>[
        idB,
        idA,
      ]);
    } finally {
      library.close();
      tmp.deleteSync(recursive: true);
    }
  });

  test('ink settings notify listeners', () {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-inkset');
    final library = Library('${tmp.path}/library.db');
    try {
      final controller = ReaderController(
        book: Book(title: 't', path: '', formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        var notifications = 0;
        controller.addListener(() => notifications++);

        controller.setInkMode(true);
        controller.setInkTool(InkTool.eraser);
        controller.setInkColor(0xFF00FF00);
        controller.setInkWidth(4);
        expect(notifications, 4);
        expect(controller.inkMode, isTrue);
        expect(controller.inkTool, InkTool.eraser);
        expect(controller.inkColor, 0xFF00FF00);
        expect(controller.inkWidth, 4);

        // A repeated value or an invalid width changes nothing.
        controller.setInkMode(true);
        controller.setInkWidth(-1);
        expect(notifications, 4);
      } finally {
        controller.dispose();
      }
    } finally {
      library.close();
      tmp.deleteSync(recursive: true);
    }
  });

  test('ink strokes persist across readers and undo/redo edit them', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-ink');
    try {
      final bookFile = File('${tmp.path}/book.epub')
        ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
      final library = Library('${tmp.path}/library.db');
      final id = library.addBook(
        Book(title: 't', path: bookFile.path, formats: ['epub']),
      );
      final book = Book(
        id: id,
        title: 't',
        path: bookFile.path,
        formats: ['epub'],
      );
      final controller = ReaderController(
        book: book,
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.inkStrokes, isEmpty);
        expect(controller.canUndoInk, isFalse);
        expect(controller.canRedoInk, isFalse);

        final stroke = _textStroke();
        final strokeId = controller.addInkStroke(stroke);
        expect(strokeId, greaterThan(0));
        expect(controller.inkStrokes.single.id, strokeId);
        expect(controller.canUndoInk, isTrue);
        expect(library.listInkStrokes(id, 0), hasLength(1));

        // Reopening the book reads the persisted stroke back.
        final reopened = ReaderController(
          book: book,
          library: library,
          stats: ReadingStatsTracker(library),
        );
        await reopened.load();
        expect(reopened.inkStrokes, hasLength(1));
        expect(reopened.inkStrokes.single.anchor.kind, InkAnchorKind.text);
        expect(reopened.inkStrokes.single.anchor.start, 0);
        expect(reopened.inkStrokes.single.anchor.end, 5);
        expect(reopened.inkStrokes.single.color, stroke.color);
        reopened.dispose();

        controller.undoInk();
        expect(controller.inkStrokes, isEmpty);
        expect(controller.canUndoInk, isFalse);
        expect(controller.canRedoInk, isTrue);
        expect(library.listInkStrokes(id, 0), isEmpty);

        controller.redoInk();
        expect(controller.inkStrokes, hasLength(1));
        expect(controller.canRedoInk, isFalse);
        expect(library.listInkStrokes(id, 0), hasLength(1));

        controller.eraseInkStroke(controller.inkStrokes.single);
        expect(controller.inkStrokes, isEmpty);
        expect(library.listInkStrokes(id, 0), isEmpty);

        controller.undoInk();
        expect(controller.inkStrokes, hasLength(1));
        expect(library.listInkStrokes(id, 0), hasLength(1));
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('ink reloads on chapter change and clears undo history', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-ink-nav');
    try {
      final bookFile = File('${tmp.path}/broken.epub')
        ..writeAsBytesSync(_epubWithBrokenSecondChapter());
      final library = Library('${tmp.path}/library.db');
      final id = library.addBook(
        Book(title: 't', path: bookFile.path, formats: ['epub']),
      );
      final controller = ReaderController(
        book: Book(id: id, title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        controller.addInkStroke(_textStroke());
        expect(controller.inkStrokes, hasLength(1));
        expect(controller.canUndoInk, isTrue);

        controller.next();
        expect(controller.index, 1);
        expect(controller.inkStrokes, isEmpty);
        expect(controller.canUndoInk, isFalse);
        expect(controller.canRedoInk, isFalse);

        // Coming back reloads the first chapter's stroke.
        controller.previous();
        expect(controller.index, 0);
        expect(controller.inkStrokes, hasLength(1));
        expect(library.listInkStrokes(id, 0), hasLength(1));
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('page ink collects page anchors across PDF pages', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-pageink');
    try {
      final file = File('${tmp.path}/pages.pdf')
        ..writeAsBytesSync(_pdfPages(2));
      final library = Library('${tmp.path}/library.db');
      final id = library.addBook(
        Book(title: 'p', path: file.path, formats: ['pdf']),
      );
      final controller = ReaderController(
        book: Book(id: id, title: 'p', path: file.path, formats: ['pdf']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.isPdf, isTrue);
        controller.addInkStroke(_pageStroke(controller.index));
        controller.addInkStroke(_textStroke());
        controller.next();
        controller.addInkStroke(_pageStroke(controller.index));

        final pages = controller.pageInkStrokes();
        expect(pages, hasLength(2));
        expect(pages.map((stroke) => stroke.anchor.chapter), <int>[0, 1]);
        expect(
          pages.every((stroke) => stroke.anchor.kind == InkAnchorKind.page),
          isTrue,
        );

        // Zoom changes display pixels, not the stored page geometry.
        final points = pages.first.points.toList();
        controller.zoomIn();
        expect(controller.pageInkStrokes().first.points, points);
      } finally {
        controller.dispose();
        library.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('ink without a saved book id stays in memory only', () async {
    final tmp = Directory.systemTemp.createTempSync('vellum-reader-noid');
    final library = Library('${tmp.path}/library.db');
    try {
      final bookFile = File('${tmp.path}/book.epub')
        ..writeAsBytesSync(base64Decode(_singleChapterEpub()));
      final controller = ReaderController(
        book: Book(title: 't', path: bookFile.path, formats: ['epub']),
        library: library,
        stats: ReadingStatsTracker(library),
      );
      try {
        await controller.load();
        expect(controller.addInkStroke(_textStroke()), -1);
        expect(controller.inkStrokes, hasLength(1));
        expect(controller.pageInkStrokes(), isEmpty);

        controller.eraseInkStroke(controller.inkStrokes.single);
        expect(controller.inkStrokes, isEmpty);
      } finally {
        controller.dispose();
      }
    } finally {
      library.close();
      tmp.deleteSync(recursive: true);
    }
  });
}

/// A text-anchored stroke used by the ink tests.
InkStroke _textStroke() => InkStroke(
  anchor: InkAnchor(
    kind: InkAnchorKind.text,
    chapter: 0,
    start: 0,
    end: 5,
    rect: Rect.fromLTWH(10, 20, 40, 18),
  ),
  color: 0xFF112233,
  width: 2.5,
  points: Float32List.fromList(<double>[0.1, 0.5, 1, 0.9, 0.5, 1]),
);

/// A page-anchored stroke used by the ink tests.
InkStroke _pageStroke(int chapter) => InkStroke(
  anchor: InkAnchor(
    kind: InkAnchorKind.page,
    chapter: chapter,
    rect: Rect.fromLTWH(0, 0, 100, 100),
  ),
  color: 0xFF445566,
  width: 3,
  points: Float32List.fromList(<double>[0.2, 0.2, 1, 0.8, 0.8, 1]),
);

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
  return _encodePdf(<String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [$mediaBox] >>',
  ]);
}

/// Minimal PDF with [count] empty 100x100 pages.
Uint8List _pdfPages(int count) {
  final kids = <String>[for (var i = 0; i < count; i++) '${i + 3} 0 R'];
  return _encodePdf(<String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count $count >>',
    for (var i = 0; i < count; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>',
  ]);
}

Uint8List _encodePdf(List<String> objects) {
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
    ..addFile(
      ArchiveFile.string(
        'OEBPS/ch1.xhtml',
        '<html><body><p>hello world</p></body></html>',
      ),
    );
  return base64Encode(ZipEncoder().encode(archive));
}

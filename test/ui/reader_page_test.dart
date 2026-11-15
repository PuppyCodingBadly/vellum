/// Widget tests for [ReaderPage] with a seeded EPUB: chapter text renders,
/// the font-scale control changes the document font size and persists, and
/// next-chapter navigation works.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/ink.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/reader/document_model.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/ink/ink_surface.dart';
import 'package:vellum/ui/ink/ink_toolbar.dart';
import 'package:vellum/ui/reader_page.dart';
import '../support/test_support.dart';

double _readerFontSize(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;

/// The bounds a surface currently gives a stroke: the union of its line boxes,
/// or the stored anchor rect when the surface reports no lines.
Rect _surfaceBounds(InkSurface surface, InkStroke stroke) {
  final lines = surface.linesFor(stroke);
  return lines.isEmpty
      ? stroke.anchor.rect
      : lines.reduce((a, b) => a.expandToInclude(b));
}

void main() {
  late Directory tmp;
  late String configPath;
  late Library library;
  late AppState state;
  late Book book;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-reader-ui-');
    configPath = p.join(tmp.path, 'config.json');
    library = Library(p.join(tmp.path, 'library.db'));
    state = AppState(
      config: VellumConfig(configPath),
      library: library,
      engine: MetadataEngine(),
      plugins: PluginController(
        pluginDir: p.join(tmp.path, 'plugins'),
        client: EmptySidecar(),
      ),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
    );
    final id = library.addBook(
      Book(
        title: 'The Smoke Test Book',
        authors: const ['Test Author'],
        formats: const ['epub'],
        path: buildTestEpub(p.join(tmp.path, 'smoke.epub')),
      ),
    );
    book = library.getBook(id)!;
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> openReader(WidgetTester tester, {bool settle = true}) async {
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderPage(book: book),
                    ),
                  ),
                  child: const Text('Open book'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open book'));
    if (!settle) {
      // A rendering PDF page keeps a spinner animating, so settling would
      // never finish; pump the route in and let the caller wait for pixels.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      return;
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'seeded EPUB renders chapter text; font scale and next chapter work',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await openReader(tester);

      // Chapter one text is rendered.
      expect(
        find.textContaining('moonstone lantern', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('phrase number 1', findRichText: true),
        findsOneWidget,
      );

      // The font-scale control grows the document font and persists the scale.
      final before = _readerFontSize(tester);
      await tester.tap(find.byTooltip('Increase font size'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final after = _readerFontSize(tester);
      expect(after, greaterThan(before));
      expect(state.readerFontScale, 1.1);
      expect(VellumConfig(configPath).getDouble('reader_font_scale'), 1.1);

      // Next-chapter navigation swaps the document text.
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('phrase number 2', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('phrase number 1', findRichText: true),
        findsNothing,
      );

      // Leaving the reader records the reading session.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Open book'), findsOneWidget);
      expect(library.recentReadingSessions(10), isNotEmpty);
    },
  );

  testWidgets('a highlight jump accounts for a leading image', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final id = library.addBook(
      Book(
        title: 'Image Book',
        formats: const ['epub'],
        path: buildImageEpub(p.join(tmp.path, 'image.epub')),
      ),
    );
    book = library.getBook(id)!;
    // The fixture parser resolves images from its base directory, exactly as
    // the reader does from the extracted chapter.
    File(p.join(tmp.path, 'tall.png')).writeAsBytesSync(tallPng());
    final document = DocumentModel.fromHtml(
      imageChapterHtml(),
      baseDirectory: tmp.path,
    );
    final start = document.plainText.indexOf('needle');
    expect(start, greaterThan(0));
    library.addHighlight(
      book.id!,
      jsonEncode(<String, Object?>{
        'chapter': 0,
        'start': start,
        'end': start + 6,
        'quote': 'needle',
      }),
      'yellow',
      'needle',
    );

    await openReader(tester);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    await tester.runAsync(() async {
      await pumpUntil(tester, () => scroll.position.maxScrollExtent > 800);
    });

    final viewportTop = tester
        .getTopLeft(find.byType(SingleChildScrollView))
        .dy;
    final viewportHeight = tester
        .getSize(find.byType(SingleChildScrollView))
        .height;
    final renderedOffset = document.documentStartToRendered(start);
    final before = renderEditableOf(tester);
    final caretBefore = before.localToGlobal(
      before.getLocalRectForCaret(TextPosition(offset: renderedOffset)).topLeft,
    );
    expect(
      caretBefore.dy - viewportTop,
      greaterThan(viewportHeight),
      reason: 'the highlighted line starts below the visible chapter',
    );

    await tester.tap(find.byTooltip('Highlights'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('needle'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await pumpUntil(tester, () => scroll.position.pixels > 0);
    });

    final after = renderEditableOf(tester);
    final caretAfter = after.localToGlobal(
      after.getLocalRectForCaret(TextPosition(offset: renderedOffset)).topLeft,
    );
    expect(caretAfter.dy, greaterThan(viewportTop));
    expect(caretAfter.dy, lessThan(viewportTop + viewportHeight));

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
  });

  testWidgets('restoring a fraction waits for inline images to lay out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final id = library.addBook(
      Book(
        title: 'Image Book',
        formats: const ['epub'],
        path: buildImageEpub(p.join(tmp.path, 'restore.epub')),
      ),
    );
    book = library.getBook(id)!;
    library.setReadingPosition(book.id!, 'epub:0:0.5000', progress: 0.5);

    await openReader(tester);
    final scroll = tester
        .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .controller!;
    await tester.runAsync(() async {
      await pumpUntil(
        tester,
        () =>
            scroll.position.maxScrollExtent > 800 && scroll.position.pixels > 0,
      );
    });

    expect(scroll.position.maxScrollExtent, greaterThan(800));
    expect(
      scroll.position.pixels,
      closeTo(scroll.position.maxScrollExtent * 0.5, 2.0),
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
  });

  testWidgets('stylus ink persists across visits and survives font scaling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openReader(tester);
    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();

    await _drawOnText(tester);
    final drawn = tester.widget<InkSurface>(find.byType(InkSurface));
    expect(drawn.strokes, hasLength(1));
    final stroke = drawn.strokes.single;
    expect(stroke.anchor.kind, InkAnchorKind.text);
    expect(stroke.anchor.end, greaterThan(stroke.anchor.start));
    // The draw-time line boxes are stored with the anchor.
    expect(stroke.anchor.lines, isNotEmpty);
    expect(library.listInkStrokes(book.id!, 0), hasLength(1));

    // A chapter visit drops the ink and coming back reads it from the DB.
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(tester.widget<InkSurface>(find.byType(InkSurface)).strokes, isEmpty);
    await tester.tap(find.byTooltip('Previous'));
    await tester.pumpAndSettle();
    final reloadedSurface = tester.widget<InkSurface>(find.byType(InkSurface));
    expect(reloadedSurface.strokes, hasLength(1));
    final reloaded = reloadedSurface.strokes.single;
    expect(reloaded.anchor.start, stroke.anchor.start);
    expect(reloaded.anchor.end, stroke.anchor.end);

    // A font-size change keeps the stroke over the same character range.
    final before = _surfaceBounds(reloadedSurface, reloaded);
    await tester.tap(find.byTooltip('Increase font size'));
    await tester.pumpAndSettle();
    final scaledSurface = tester.widget<InkSurface>(find.byType(InkSurface));
    final afterLines = scaledSurface.linesFor(reloaded);
    final after = _surfaceBounds(scaledSurface, reloaded);
    expect(reloaded.anchor.start, stroke.anchor.start);
    expect(reloaded.anchor.end, stroke.anchor.end);
    expect(after.overlaps(before), isTrue);
    // The points are re-mapped into the rescaled line boxes, not the old ones.
    for (var i = 0; i < reloaded.pointCount; i++) {
      expect(
        after.inflate(1).contains(inkPointInLines(reloaded, i, afterLines)),
        isTrue,
      );
    }
  });

  testWidgets('eraser, undo and redo edit stored ink', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openReader(tester);
    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();
    final start = await _drawOnText(tester);
    expect(library.listInkStrokes(book.id!, 0), hasLength(1));

    var toolbar = tester.widget<InkToolbar>(find.byType(InkToolbar));
    expect(toolbar.canUndo, isTrue);
    expect(toolbar.canRedo, isFalse);

    toolbar.onUndo();
    await tester.pumpAndSettle();
    expect(library.listInkStrokes(book.id!, 0), isEmpty);
    toolbar = tester.widget<InkToolbar>(find.byType(InkToolbar));
    expect(toolbar.canUndo, isFalse);
    expect(toolbar.canRedo, isTrue);

    toolbar.onRedo();
    await tester.pumpAndSettle();
    expect(library.listInkStrokes(book.id!, 0), hasLength(1));

    // The eraser removes only the hit stroke; undo restores it.
    tester.widget<InkToolbar>(find.byType(InkToolbar)).onTool(InkTool.eraser);
    await tester.pump();
    final erase = await tester.startGesture(
      start + const Offset(25, 2),
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();
    await erase.up();
    await tester.pumpAndSettle();
    expect(library.listInkStrokes(book.id!, 0), isEmpty);
    toolbar = tester.widget<InkToolbar>(find.byType(InkToolbar));
    expect(toolbar.canUndo, isTrue);
    toolbar.onUndo();
    await tester.pumpAndSettle();
    expect(library.listInkStrokes(book.id!, 0), hasLength(1));
  });

  testWidgets('ink mode toggles the toolbar and restores selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openReader(tester);
    expect(find.byType(InkToolbar), findsNothing);
    expect(tester.widget<InkSurface>(find.byType(InkSurface)).enabled, isFalse);
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .enableInteractiveSelection,
      isNot(false),
    );
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isNull,
    );

    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();
    expect(find.byType(InkToolbar), findsOneWidget);
    expect(tester.widget<InkSurface>(find.byType(InkSurface)).enabled, isTrue);
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .enableInteractiveSelection,
      isFalse,
    );
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isA<NeverScrollableScrollPhysics>(),
    );

    tester.widget<InkToolbar>(find.byType(InkToolbar)).onClose();
    await tester.pumpAndSettle();
    expect(find.byType(InkToolbar), findsNothing);
    expect(tester.widget<InkSurface>(find.byType(InkSurface)).enabled, isFalse);
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isNull,
    );
    expect(
      tester
          .widget<SelectableText>(find.byType(SelectableText))
          .enableInteractiveSelection,
      isNot(false),
    );
  });

  testWidgets('compact 480px header fits the ink controls', (tester) async {
    tester.view.physicalSize = const Size(480, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openReader(tester);
    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();
    expect(find.byType(InkToolbar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a PDF page stroke survives zoom', (tester) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = p.join(tmp.path, 'page.pdf');
    File(path).writeAsBytesSync(_singlePagePdf());
    final id = library.addBook(
      Book(title: 'PDF Book', formats: const ['pdf'], path: path),
    );
    book = library.getBook(id)!;
    await openReader(tester, settle: false);
    await tester.runAsync(() async {
      await pumpUntil(
        tester,
        () => find.byType(InkSurface).evaluate().isNotEmpty,
      );
    });
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Draw'));
    await tester.pumpAndSettle();
    final centre = tester.getCenter(find.byType(InkSurface));
    final gesture = await tester.startGesture(
      centre,
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(40, 30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final drawn = tester.widget<InkSurface>(find.byType(InkSurface));
    expect(drawn.strokes, hasLength(1));
    final stroke = drawn.strokes.single;
    expect(stroke.anchor.kind, InkAnchorKind.page);
    final before = _surfaceBounds(drawn, stroke);
    expect(before.width, greaterThan(0));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();

    // Zoom only raises the rendered resolution; the stroke stays on the same
    // page point instead of drifting with the new pixels.
    final zoomed = tester.widget<InkSurface>(find.byType(InkSurface));
    expect(zoomed.strokes, hasLength(1));
    final after = _surfaceBounds(zoomed, stroke);
    expect(after.width, closeTo(before.width, 1.0));
    expect(after.height, closeTo(before.height, 1.0));
    expect(
      after.contains(
        inkPointInLines(zoomed.strokes.single, 0, zoomed.linesFor(stroke)),
      ),
      isTrue,
    );
    expect(library.listInkStrokes(book.id!, 0), hasLength(1));

    // Tear the reader down inside the test and let the PDF worker's 2 s
    // close-ack timeout fire, so it cannot outlive the fake-async scope.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}

/// Draws a short stylus stroke over the first line of chapter text.
///
/// Returns the global point the stroke started at, so eraser tests can hit it.
Future<Offset> _drawOnText(WidgetTester tester) async {
  final editable = renderEditableOf(tester);
  final caret = editable.getLocalRectForCaret(const TextPosition(offset: 30));
  final start = editable.localToGlobal(caret.topLeft) + const Offset(1, 4);
  final gesture = await tester.startGesture(
    start,
    kind: PointerDeviceKind.stylus,
  );
  await tester.pump();
  await gesture.moveBy(const Offset(60, 3));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
  return start;
}

/// Minimal single-page PDF with an empty page.
Uint8List _singlePagePdf() {
  const objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] >>',
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
  return out.toBytes();
}

RenderEditable renderEditableOf(WidgetTester tester) {
  RenderEditable? found;
  void visit(RenderObject object) {
    if (found != null) return;
    if (object is RenderEditable) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(SelectableText)));
  return found!;
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 200,
}) async {
  for (var i = 0; i < attempts; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met');
}

List<int> tallPng() => img.encodePng(img.Image(width: 600, height: 900));

/// One chapter whose first paragraph is a 600x900 image.
String imageChapterHtml() =>
    '<html><body>'
    '<p><img src="tall.png" alt="tall image"/></p>'
    '<p>the needle phrase follows a tall image</p>'
    '<p>${'filler words ' * 200}</p>'
    '</body></html>';

String buildImageEpub(String path) {
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
    <item id="i1" href="tall.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>''';
  final png = tallPng();
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string('OEBPS/ch1.xhtml', imageChapterHtml()))
    ..addFile(ArchiveFile('OEBPS/tall.png', png.length, png));
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

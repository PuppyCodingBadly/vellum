/// End-to-end UI smoke tests: navigation, reader font scaling, shelves, stats.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/main.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/plugins/sidecar_client.dart';
import 'package:vellum/reader/reader_controller.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/widgets/book_cover.dart';

/// A sidecar that never spawns a process, so widget tests leave no timers.
class _EmptySidecar extends SidecarClient {
  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async =>
      const LoadedPlugins();

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async =>
      const LoadedPlugins();
}

String _buildEpub(String path) {
  final archive = Archive();
  archive.addFile(ArchiveFile.string('mimetype', 'application/epub+zip'));
  archive.addFile(ArchiveFile.string(
    'META-INF/container.xml',
    '<?xml version="1.0"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>',
  ));
  archive.addFile(ArchiveFile.string(
    'OEBPS/content.opf',
    '<?xml version="1.0" encoding="utf-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="bookid">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>The Smoke Test Book</dc:title>'
    '<dc:creator>Jade Kovacs</dc:creator>'
    '<dc:identifier id="bookid">urn:isbn:9780441013593</dc:identifier>'
    '<dc:language>en</dc:language></metadata>'
    '<manifest>'
    '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
    'properties="nav"/>'
    '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest><spine>'
    '<itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>'
    '</spine></package>',
  ));
  archive.addFile(ArchiveFile.string(
    'OEBPS/nav.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
    '<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol>'
    '<li><a href="ch1.xhtml">Chapter 1</a></li>'
    '<li><a href="ch2.xhtml">Chapter 2</a></li>'
    '<li><a href="ch3.xhtml">Chapter 3</a></li>'
    '</ol></nav></body></html>',
  ));
  for (var i = 1; i <= 3; i++) {
    archive.addFile(ArchiveFile.string(
      'OEBPS/ch$i.xhtml',
      '<html><body><h1>Chapter $i</h1>'
      '<p>The moonstone lantern glowed over harbour number $i.</p>'
      '<p>A distinctive phrase number $i appears here.</p>'
      '</body></html>',
    ));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

String _buildMobi(String path) {
  final text = utf8.encode(
    '<h1>Mobi Chapter</h1><p>The mobi lantern burns steadily.</p>',
  );
  final half = text.length ~/ 2;
  final palmdoc = ByteData(16)
    ..setUint16(0, 1)
    ..setUint32(4, text.length)
    ..setUint16(8, 2)
    ..setUint16(10, 4096);
  final mobi = ByteData(0x70);
  for (var i = 0; i < 4; i++) {
    mobi.setUint8(i, 'MOBI'.codeUnits[i]);
  }
  mobi
    ..setUint32(4, 0xE8)
    ..setUint32(0x0C, 65001)
    ..setUint32(0x50, 3)
    ..setUint32(0x6C, 3);
  final records = <List<int>>[
    [...palmdoc.buffer.asUint8List(), ...mobi.buffer.asUint8List()],
    text.sublist(0, half),
    text.sublist(half),
  ];
  final header = ByteData(78);
  for (var i = 0; i < 'TestBook'.length; i++) {
    header.setUint8(i, 'TestBook'.codeUnitAt(i));
  }
  for (var i = 0; i < 8; i++) {
    header.setUint8(60 + i, 'BOOKMOBI'.codeUnitAt(i));
  }
  header.setUint16(76, records.length);
  final table = BytesBuilder();
  var offset = 78 + 8 * records.length;
  for (final record in records) {
    final entry = ByteData(8)
      ..setUint32(0, offset)
      ..setUint32(4, 0);
    table.add(entry.buffer.asUint8List());
    offset += record.length;
  }
  File(path).writeAsBytesSync([
    ...header.buffer.asUint8List(),
    ...table.toBytes(),
    for (final record in records) ...record,
  ]);
  return path;
}

String _buildPdf(String path) {
  final contents = 'BT /F1 24 Tf 72 700 Td (Smoke PDF page) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${contents.length} >>\nstream\n$contents\nendstream',
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
  out.add('trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n'
      .codeUnits);
  File(path).writeAsBytesSync(out.toBytes());
  return path;
}

/// Builds the root widget against a fresh temp library and fake sidecar.
Widget _app(
  VellumConfig config,
  Library library,
  FtsIndexer fts,
  ReadingStatsTracker stats,
) {
  return VellumApp(
    config: config,
    library: library,
    engine: MetadataEngine(),
    plugins: PluginController(
      pluginDir: '${Directory(config.path).parent.path}/plugins',
      client: _EmptySidecar(),
    ),
    fts: fts,
    stats: stats,
  );
}

double _readerFontSize(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;

void main() {
  testWidgets('library, reader, shelves, plugins and stats render',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('vellum-ui-smoke-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final library = Library('${dir.path}/library.db');
    addTearDown(library.close);
    library.addBook(Book(
      title: 'The Smoke Test Book',
      authors: const ['Jade Kovacs'],
      formats: const ['epub'],
      path: _buildEpub('${dir.path}/smoke.epub'),
      description: 'A tiny three-chapter book.',
    ));
    final config = VellumConfig('${dir.path}/config.json');
    final fts = FtsIndexer(library);
    final stats = ReadingStatsTracker(library);
    await tester.runAsync(fts.indexAll);

    await tester.pumpWidget(_app(config, library, fts, stats));
    await tester.pumpAndSettle();

    expect(find.text('The Smoke Test Book'), findsOneWidget);

    // Full-text content search appears above the grid.
    await tester.enterText(find.byType(TextField).first, 'moonstone');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('In book text'), findsOneWidget);
    expect(find.textContaining('moonstone lantern'), findsWidgets);

    // Open the same book from the content hit.
    await tester.tap(find.textContaining('moonstone lantern').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('moonstone lantern', findRichText: true),
        findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // Clear the query, open details, then the reader.
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BookCard).first);
    await tester.pumpAndSettle();
    expect(find.text('Fetch Metadata'), findsOneWidget);
    expect(find.text('Jade Kovacs'), findsOneWidget);

    await tester.tap(find.text('Read'));
    await tester.pumpAndSettle();
    expect(find.textContaining('moonstone lantern', findRichText: true),
        findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    await tester.pumpAndSettle();
    expect(find.textContaining('phrase number 2', findRichText: true),
        findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // Shelves: create, open, and add the book.
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Shelves'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('New Shelf'), findsOneWidget);
    await tester.tap(find.text('New Shelf'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Favourites');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Favourites').first);
    await tester.pumpAndSettle();
    expect(find.text('No books on this shelf'), findsOneWidget);
    await tester.tap(find.text('Add books…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Smoke Test Book'));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('The Smoke Test Book'), findsOneWidget);

    // Other tabs reach their empty states.
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Get Books'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('No store plugins'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Plugins'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Installed Plugins'), findsOneWidget);

    // Reading sessions persist after the reader is closed.
    expect(library.recentReadingSessions(10), isNotEmpty);
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Stats'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Reading Statistics'), findsOneWidget);
    expect(find.text('Recent sessions'), findsOneWidget);
    expect(find.text('The Smoke Test Book'), findsWidgets);
  });

  testWidgets('font size changes apply to EPUB and MOBI readers',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('vellum-font-smoke-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final library = Library('${dir.path}/library.db');
    addTearDown(library.close);
    library.addBook(Book(
      title: 'The Smoke Test Book',
      formats: const ['epub'],
      path: _buildEpub('${dir.path}/smoke.epub'),
    ));
    library.addBook(Book(
      title: 'Mobi Smoke Book',
      formats: const ['mobi'],
      path: _buildMobi('${dir.path}/smoke.mobi'),
    ));
    final config = VellumConfig('${dir.path}/config.json');
    final fts = FtsIndexer(library);
    final stats = ReadingStatsTracker(library);

    await tester.pumpWidget(_app(config, library, fts, stats));
    await tester.pumpAndSettle();

    for (final title in ['The Smoke Test Book', 'Mobi Smoke Book']) {
      await tester.tap(find.ancestor(
        of: find.text(title),
        matching: find.byType(BookCard),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      final before = _readerFontSize(tester);
      await tester.tap(find.byTooltip('Increase font size'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final after = _readerFontSize(tester);
      expect(after, greaterThan(before), reason: '$title font scale');
      await tester.tap(find.byTooltip('Decrease font size'));
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }
  });

  test('PDF font scale re-renders larger pages', () async {
    final dir = Directory.systemTemp.createTempSync('vellum-pdf-font-');
    final library = Library('${dir.path}/library.db');
    final book = Book(
      title: 'Pdf Smoke Book',
      formats: const ['pdf'],
      path: _buildPdf('${dir.path}/smoke.pdf'),
    );
    library.addBook(book);
    final controller = ReaderController(
      book: book,
      library: library,
      stats: ReadingStatsTracker(library),
    );
    try {
      await controller.load();
      final before = await _waitForPdfPage(controller);
      final beforeWidth = img.decodePng(before)!.width;

      controller.setFontScale(1.6);
      final after =
          await _waitForPdfPage(controller, differentFrom: before);
      final afterWidth = img.decodePng(after)!.width;

      expect(controller.fontScale, 1.6);
      expect(afterWidth, greaterThan(beforeWidth));
    } finally {
      controller.dispose();
      library.close();
      dir.deleteSync(recursive: true);
    }
  });
}

Future<Uint8List> _waitForPdfPage(
  ReaderController controller, {
  Uint8List? differentFrom,
}) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final bytes = controller.pdfPageBytes;
    if (bytes != null && !identical(bytes, differentFrom)) return bytes;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('PDF page did not render');
}

/// Widget tests for [ReaderPage] with a seeded EPUB: chapter text renders,
/// the font-scale control changes the document font size and persists, and
/// next-chapter navigation works.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/reader_page.dart';
import '../support/test_support.dart';

double _readerFontSize(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;

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
    final id = library.addBook(Book(
      title: 'The Smoke Test Book',
      authors: const ['Test Author'],
      formats: const ['epub'],
      path: buildTestEpub(p.join(tmp.path, 'smoke.epub')),
    ));
    book = library.getBook(id)!;
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> openReader(WidgetTester tester) async {
    await tester.pumpWidget(AppStateScope(
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
    ));
    await tester.tap(find.text('Open book'));
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
    expect(find.textContaining('moonstone lantern', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('phrase number 1', findRichText: true),
        findsOneWidget);

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
    expect(find.textContaining('phrase number 2', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('phrase number 1', findRichText: true),
        findsNothing);

    // Leaving the reader records the reading session.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open book'), findsOneWidget);
    expect(library.recentReadingSessions(10), isNotEmpty);
  });
}

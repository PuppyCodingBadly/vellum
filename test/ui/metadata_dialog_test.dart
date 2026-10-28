/// Widget tests for [MetadataDialog]: the search field drives the metadata
/// engine seam and applying a result updates the book in the library.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/metadata_dialog.dart';
import '../support/test_support.dart';

/// An offline metadata engine: [find] stays empty (so the dialog's automatic
/// search reaches the empty state) while [findQuery] serves canned results.
class _FakeEngine extends MetadataEngine {
  List<Metadata> queryResults = [];
  final List<String> queries = [];
  int findCalls = 0;

  @override
  Future<List<Metadata>> find({
    String title = '',
    List<String>? authors,
    String isbn = '',
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    findCalls++;
    return const [];
  }

  @override
  Future<List<Metadata>> findQuery(
    String query, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    queries.add(query);
    return queryResults;
  }

  @override
  Future<Uint8List?> fetchCover(
    Metadata meta, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      null;
}

void main() {
  late Directory tmp;
  late Library library;
  late _FakeEngine engine;
  late AppState state;
  late Book book;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-metadata-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    engine = _FakeEngine();
    state = AppState(
      config: VellumConfig(p.join(tmp.path, 'config.json')),
      library: library,
      engine: engine,
      plugins: PluginController(
        pluginDir: p.join(tmp.path, 'plugins'),
        client: EmptySidecar(),
      ),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
    );
    final id = library.addBook(Book(
      title: 'Original Title',
      authors: const ['Original Author'],
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));
    book = library.getBook(id)!;
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(AppStateScope(
      state: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => MetadataDialog(book: book),
                ),
                child: const Text('Fetch Metadata'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Fetch Metadata'));
    await tester.pumpAndSettle();
  }

  testWidgets('search hits the engine seam; applying a result updates the book',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    engine.queryResults = [
      Metadata(
        title: 'Fetched Title',
        authors: const ['Fetched Author'],
        isbn: '9780441013593',
        publisher: 'Ace Books',
        rating: 4.2,
        sourceId: 'fake',
        sourceName: 'Fake Source',
      ),
    ];

    await openDialog(tester);

    // The automatic search ran against the (empty) engine and plugin seams.
    expect(engine.findCalls, 1);
    expect(find.text('No Results'), findsOneWidget);

    // Typing a query dispatches a free-text search to the engine.
    await tester.enterText(find.byType(TextField).first, 'fetched');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(engine.queries, ['fetched']);
    expect(find.text('Fetched Title'), findsOneWidget);
    expect(find.text('Fetched Author'), findsOneWidget);

    // Picking the result applies it to the book and closes the dialog.
    await tester.tap(find.text('Fetched Title'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.text('No Results'), findsNothing); // dialog closed
    final updated = library.getBook(book.id!)!;
    expect(updated.title, 'Fetched Title');
    expect(updated.authors, ['Fetched Author']);
    expect(updated.isbn, '9780441013593');
    expect(updated.publisher, 'Ace Books');
    expect(updated.rating, 4.2);
  });
}

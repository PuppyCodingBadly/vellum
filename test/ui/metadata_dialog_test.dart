/// Widget tests for [MetadataDialog]: the search field drives the metadata
/// engine seam and applying a result updates the book in the library.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
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

  /// When set, [fetchCover] waits on it so a test can dismiss the dialog with
  /// an apply still in flight.
  Completer<Uint8List?>? coverGate;

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
  }) async {
    final gate = coverGate;
    if (gate == null) return null;
    return gate.future;
  }
}

/// An [AppState] that keeps cover files in the test's temp directory instead
/// of the real data directory.
class _TempDataState extends AppState {
  _TempDataState({
    required super.config,
    required super.library,
    required super.engine,
    required super.plugins,
    required super.fts,
    required super.stats,
    required this.dataDir,
  });

  @override
  final String dataDir;
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
    state = _TempDataState(
      config: VellumConfig(p.join(tmp.path, 'config.json')),
      library: library,
      engine: engine,
      plugins: PluginController(
        pluginDir: p.join(tmp.path, 'plugins'),
        client: EmptySidecar(),
      ),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
      dataDir: tmp.path,
    );
    final id = library.addBook(
      Book(
        title: 'Original Title',
        authors: const ['Original Author'],
        formats: const ['epub'],
        path: '/nonexistent.epub',
      ),
    );
    book = library.getBook(id)!;
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      AppStateScope(
        state: state,
        child: MaterialApp(
          scaffoldMessengerKey: state.messengerKey,
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
      ),
    );
    await tester.tap(find.text('Fetch Metadata'));
    await tester.pumpAndSettle();
  }

  /// Opens the dialog, runs a query and selects the single result.
  Future<void> pickResult(WidgetTester tester, String title) async {
    await openDialog(tester);
    await tester.enterText(find.byType(TextField).first, 'fetched');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pump();
  }

  /// Lets real `dart:io` work settle: `testWidgets` fakes the clock, and file
  /// futures never complete under it.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets(
    'search hits the engine seam; applying a result updates the book',
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
    },
  );

  testWidgets('closing while apply waits cancels the save and the toast', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    engine.queryResults = [
      Metadata(
        title: 'Fetched Title',
        authors: const ['Fetched Author'],
        sourceId: 'fake',
        sourceName: 'Fake Source',
      ),
    ];
    final gate = Completer<Uint8List?>();
    engine.coverGate = gate;

    await openDialog(tester);
    await tester.enterText(find.byType(TextField).first, 'fetched');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fetched Title'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pump();
    expect(find.text('Applying…'), findsOneWidget);

    // Dismiss while the cover is still being fetched.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    gate.complete(null);
    await tester.pump();
    await tester.pump();

    expect(book.title, 'Original Title');
    expect(book.authors, ['Original Author']);
    final stored = library.getBook(book.id!)!;
    expect(stored.title, 'Original Title');
    expect(stored.authors, ['Original Author']);
    expect(find.textContaining('Metadata applied'), findsNothing);
  });

  testWidgets('a failed book save leaves the previous cover untouched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final covers = Directory(p.join(tmp.path, 'covers'))
      ..createSync(recursive: true);
    final oldBytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x42];
    final oldCover = File(p.join(covers.path, '${book.id}.jpg'))
      ..writeAsBytesSync(oldBytes);
    library.updateBook(book..coverPath = oldCover.path);

    final gate = Completer<Uint8List?>();
    engine.coverGate = gate;
    engine.queryResults = [
      Metadata(
        title: 'Fetched Title',
        sourceId: 'fake',
        sourceName: 'Fake Source',
      ),
    ];
    await pickResult(tester, 'Fetched Title');

    // The row disappears, so the save after the cover download is refused.
    library.deleteBook(book.id!);
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await tester.runAsync(() async {
      gate.complete(
        Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 6))),
      );
    });
    await settleIo(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed to save book'), findsOneWidget);
    expect(
      oldCover.readAsBytesSync(),
      oldBytes,
      reason: 'the old artwork is only replaced by a successful save',
    );
    expect(covers.listSync().map((entry) => p.basename(entry.path)).toList(), [
      '${book.id}.jpg',
    ], reason: 'no new cover and no temp file left behind');
  });

  testWidgets('applying replaces the cover and keeps generated artwork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final covers = Directory(p.join(tmp.path, 'covers'))
      ..createSync(recursive: true);
    final oldCover = File(p.join(covers.path, '${book.id}.jpg'))
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0x01]);
    final generated = File(p.join(covers.path, 'generated-${book.id}.png'))
      ..writeAsBytesSync([7, 7, 7]);
    library.updateBook(book..coverPath = oldCover.path);

    final png = img.encodePng(img.Image(width: 5, height: 7));
    engine.coverGate = Completer<Uint8List?>()..complete(png);
    engine.queryResults = [
      Metadata(
        title: 'Fetched Title',
        sourceId: 'fake',
        sourceName: 'Fake Source',
      ),
    ];
    await pickResult(tester, 'Fetched Title');
    await tester.tap(find.text('Apply'));
    await tester.pump();
    await settleIo(tester);
    await tester.pumpAndSettle();

    final expected = p.join(covers.path, '${book.id}.png');
    expect(library.getBook(book.id!)!.coverPath, expected);
    expect(File(expected).readAsBytesSync(), png);
    expect(
      oldCover.existsSync(),
      isFalse,
      reason: 'the JPEG it replaced is deleted',
    );
    expect(generated.readAsBytesSync(), [7, 7, 7]);
    expect(
      covers.listSync().map((entry) => p.basename(entry.path)).toList()..sort(),
      ['${book.id}.png', 'generated-${book.id}.png'],
      reason: 'no staged temp file survives the rename',
    );
  });
}

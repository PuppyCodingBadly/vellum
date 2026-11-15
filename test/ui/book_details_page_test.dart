/// Widget tests for [BookDetailsPage]: seeded metadata rendering, the
/// Fetch Metadata dispatch and the hide/unhide action.
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
import 'package:vellum/plugins/sidecar_client.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/book_details_page.dart';

/// A sidecar that never spawns a process and records metadata searches.
class _RecordingSidecar extends SidecarClient {
  final List<Map<String, Object?>> metadataSearches = [];

  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async =>
      const LoadedPlugins();

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async =>
      const LoadedPlugins();

  @override
  Future<List<Map<String, Object?>>> metadataSearch({
    String title = '',
    List<String>? authors,
    String isbn = '',
    double timeout = 15.0,
  }) async {
    metadataSearches.add({'title': title, 'authors': authors, 'isbn': isbn});
    return const [];
  }
}

void main() {
  late Directory tmp;
  late Library library;
  late _RecordingSidecar sidecar;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-details-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    sidecar = _RecordingSidecar();
    state = AppState(
      config: VellumConfig(p.join(tmp.path, 'config.json')),
      library: library,
      engine: MetadataEngine(),
      plugins: PluginController(
        pluginDir: p.join(tmp.path, 'plugins'),
        client: sidecar,
      ),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
    );
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Book seedBook() {
    final id = library.addBook(Book(
      title: 'Detail Book',
      authors: const ['Jane Doe'],
      publisher: 'Acme Publishing',
      pubdate: '2020',
      language: 'en',
      isbn: '9781234567890',
      description: 'A seeded description.',
      tags: const ['fiction'],
      rating: 4.0,
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));
    return library.getBook(id)!;
  }

  Widget wrap(Book book) => AppStateScope(
        state: state,
        child: MaterialApp(home: BookDetailsPage(book: book)),
      );

  testWidgets('shows title, authors and metadata of a seeded book',
      (tester) async {
    final book = seedBook();

    await tester.pumpWidget(wrap(book));
    await tester.pump();

    // AppBar title plus the header headline.
    expect(find.text('Detail Book'), findsWidgets);
    expect(find.text('Jane Doe'), findsOneWidget);
    expect(find.textContaining('★★★★'), findsOneWidget);
    expect(find.text('fiction'), findsOneWidget);
    expect(find.text('Publisher'), findsOneWidget);
    expect(find.text('Acme Publishing'), findsOneWidget);
    expect(find.text('ISBN'), findsOneWidget);
    expect(find.text('9781234567890'), findsOneWidget);
    expect(find.text('A seeded description.'), findsOneWidget);
    expect(find.text('Fetch Metadata'), findsOneWidget);
  });

  testWidgets('Fetch Metadata dispatches a search through the sidecar',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final book = seedBook();
    await tester.pumpWidget(wrap(book));
    await tester.pump();

    await tester.tap(find.text('Fetch Metadata'));
    await tester.pumpAndSettle();

    // The dialog auto-searched with the book's metadata; with no sources
    // and no plugins it reaches the empty state.
    expect(find.text('No Results'), findsOneWidget);
    expect(sidecar.metadataSearches, hasLength(1));
    expect(sidecar.metadataSearches.single['title'], 'Detail Book');
    expect(sidecar.metadataSearches.single['authors'], ['Jane Doe']);
    expect(sidecar.metadataSearches.single['isbn'], '9781234567890');

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('No Results'), findsNothing);
  });

  testWidgets('read progress appears among the facts', (tester) async {
    final book = seedBook();
    library.setReadingPosition(book.id!, 'epub:2:0.5000', progress: 0.43);
    final resumed = library.getBook(book.id!)!;

    await tester.pumpWidget(wrap(resumed));
    await tester.pump();

    expect(find.text('Progress'), findsOneWidget);
    expect(find.text('43%'), findsOneWidget);
  });

  testWidgets('Generate Cover saves a PNG and points the book at it',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final book = seedBook();
    await tester.pumpWidget(wrap(book));
    await tester.pump();

    await tester.tap(find.text('Generate Cover'));
    await tester.pump();
    // The preview future renders a PNG off the test clock; the spinner would
    // never settle until it resolves.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('Use Cover'), findsOneWidget);

    await tester.tap(find.text('Use Cover'));
    // showDialog's future completes only once the route's reverse transition
    // finishes, so settle the route before waiting for the file write.
    await tester.pumpAndSettle();
    for (var attempt = 0;
        attempt < 20 && library.getBook(book.id!)!.coverPath.isEmpty;
        attempt++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Use Cover'), findsNothing);
    final fresh = library.getBook(book.id!)!;
    expect(fresh.coverPath, contains('/covers/generated-'));
    expect(File(fresh.coverPath).existsSync(), isTrue);
    expect(File(fresh.coverPath).lengthSync(), greaterThan(1000));
  });

  testWidgets('Hide Book persists the hidden flag and flips the action',
      (tester) async {
    final book = seedBook();
    await tester.pumpWidget(wrap(book));
    await tester.pump();

    expect(find.text('Hide Book'), findsOneWidget);
    await tester.tap(find.text('Hide Book'));
    await tester.pump();

    expect(library.getBook(book.id!)!.hidden, isTrue);
    expect(find.text('Unhide Book'), findsOneWidget);
  });
}

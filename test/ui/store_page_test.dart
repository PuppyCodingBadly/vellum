/// Widget tests for [StorePage]: searching dispatches to the store plugin
/// through the sidecar, results render, and downloads survive a new search.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/plugins/sidecar_client.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/store_page.dart';

/// A sidecar that never spawns a process; it reports one store plugin and
/// records searches against it.
class _StoreSidecar extends SidecarClient {
  final List<(String, String)> searches = [];

  static const LoadedPlugins _plugins = LoadedPlugins(
    stores: [
      PluginInfo(
        name: 'Test Shop',
        version: '1.0',
        description: 'Fake store plugin',
      ),
    ],
  );

  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async => _plugins;

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async => _plugins;

  @override
  Future<List<Map<String, Object?>>> storeSearch(
    String store,
    String query, {
    int maxResults = 10,
    double timeout = 60.0,
  }) async {
    searches.add((store, query));
    if (query == 'boom') throw SidecarException('store exploded');
    return [
      {
        'title': 'Store Result Book',
        'author': 'Shopy Author',
        'formats': 'epub,mobi',
        'store_name': 'Test Shop',
      },
    ];
  }

  @override
  Future<Map<String, Object?>?> storeFetchDownload(
    String store,
    Map<String, Object?> result, {
    double timeout = 60.0,
  }) async => {
    'download_url': 'https://store.example/book.epub',
    'title': (result['title'] ?? '').toString(),
    'formats': (result['formats'] ?? '').toString(),
  };
}

/// A scripted downloader: records calls and completes when the test says so.
class _Downloads {
  final List<String> calls = [];
  final Completer<File> pending = Completer<File>();

  Future<File> download({
    required String url,
    required String title,
    required String formats,
    required String directory,
  }) {
    calls.add('$title|$formats|$url');
    return pending.future;
  }
}

void main() {
  late Directory tmp;
  late Library library;
  late _StoreSidecar sidecar;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-store-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    sidecar = _StoreSidecar();
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

  Widget wrap({StoreDownload? download}) => AppStateScope(
    state: state,
    child: MaterialApp(
      scaffoldMessengerKey: state.messengerKey,
      home: Scaffold(
        body: download == null
            ? const StorePage()
            : StorePage(download: download),
      ),
    ),
  );

  Future<void> search(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'lantern');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('search dispatches to the store plugin and renders results', (
    tester,
  ) async {
    // Load the fake plugin registry before the page reads it.
    await tester.runAsync(() => state.plugins.start());

    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('Search for books'), findsOneWidget);

    await search(tester);

    // The query went through the plugin controller to the sidecar.
    expect(sidecar.searches, [('Test Shop', 'lantern')]);

    // The result row renders title, author, format chips and the action.
    expect(find.text('Store Result Book'), findsOneWidget);
    expect(find.text('Shopy Author'), findsOneWidget);
    expect(find.text('epub'), findsOneWidget);
    expect(find.text('mobi'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a failing store surfaces an error, not an empty result list', (
    tester,
  ) async {
    await tester.runAsync(() => state.plugins.start());

    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'boom');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();

    expect(sidecar.searches, [('Test Shop', 'boom')]);
    expect(find.text('Search failed'), findsOneWidget);
  });

  testWidgets('a new search keeps an in-flight download in flight', (
    tester,
  ) async {
    await tester.runAsync(() => state.plugins.start());
    final downloads = _Downloads();
    await tester.pumpWidget(wrap(download: downloads.download));
    await tester.pump();
    await search(tester);

    await tester.tap(find.text('Download'));
    await tester.pump();
    expect(downloads.calls, hasLength(1));
    expect(find.text('Download'), findsNothing);

    // Same query, same row: the guard must survive the new result list.
    await search(tester);
    expect(find.text('Download'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(downloads.calls, hasLength(1));

    // Finishing the download releases the row again.
    downloads.pending.complete(File(p.join(tmp.path, 'missing.epub')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Download'), findsOneWidget);
    expect(
      find.textContaining('could not add it to the library'),
      findsOneWidget,
    );
  });

  testWidgets('a library switch mid-download reports failure, not success', (
    tester,
  ) async {
    await tester.runAsync(() => state.plugins.start());
    final downloads = _Downloads();
    await tester.pumpWidget(wrap(download: downloads.download));
    await tester.pump();
    await search(tester);

    await tester.tap(find.text('Download'));
    await tester.pump();

    final otherDir = p.join(tmp.path, 'other-library');
    await tester.runAsync(() => state.switchLibraryDirectory(otherDir));
    expect(state.libraryDir, otherDir);

    downloads.pending.complete(File(p.join(tmp.path, 'book.epub')));
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('Library changed during download'),
      findsOneWidget,
    );
    expect(find.text('Added Store Result Book to library'), findsNothing);
    expect(state.library.allBooks(), isEmpty);
  });
}

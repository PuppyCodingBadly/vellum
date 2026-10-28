/// Widget tests for [StorePage]: searching dispatches to the store plugin
/// through the sidecar and results render.
library;

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

  Widget wrap() => AppStateScope(
        state: state,
        child: const MaterialApp(home: Scaffold(body: StorePage())),
      );

  testWidgets('search dispatches to the store plugin and renders results',
      (tester) async {
    // Load the fake plugin registry before the page reads it.
    await tester.runAsync(() => state.plugins.start());

    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('Search for books'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'lantern');
    await tester.tap(find.text('Search'));
    await tester.pump();
    await tester.pump();

    // The query went through the plugin controller to the sidecar.
    expect(sidecar.searches, [('Test Shop', 'lantern')]);

    // The result row renders title, author, format chips and the action.
    expect(find.text('Store Result Book'), findsOneWidget);
    expect(find.text('Shopy Author'), findsOneWidget);
    expect(find.text('epub'), findsOneWidget);
    expect(find.text('mobi'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a failing store surfaces an error, not an empty result list',
      (tester) async {
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
}

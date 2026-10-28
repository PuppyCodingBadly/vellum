/// Widget tests for [PluginsPage]: the installed plugin list renders and
/// removing a metadata plugin unloads it through the sidecar.
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
import 'package:vellum/ui/plugins_page.dart';

/// A sidecar that never spawns a process; it serves a mutable in-memory
/// plugin registry and records unloads.
class _PluginSidecar extends SidecarClient {
  List<PluginInfo> metadata = const [
    PluginInfo(
      name: 'Goodreads Meta',
      version: '2.1',
      description: 'Fetches metadata',
    ),
  ];
  List<PluginInfo> stores = const [
    PluginInfo(
      name: 'Test Shop',
      version: '1.0',
      description: 'Fake store plugin',
    ),
  ];
  final List<String> unloaded = [];

  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async =>
      LoadedPlugins(metadata: metadata, stores: stores);

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async =>
      LoadedPlugins(metadata: metadata, stores: stores);

  @override
  Future<bool> unload(String pluginDir, String name) async {
    unloaded.add(name);
    metadata = metadata.where((plugin) => plugin.name != name).toList();
    return true;
  }
}

void main() {
  late Directory tmp;
  late Library library;
  late _PluginSidecar sidecar;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-plugins-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    sidecar = _PluginSidecar();
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
        child: const MaterialApp(home: Scaffold(body: PluginsPage())),
      );

  testWidgets('installed plugins list renders with versions', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Installed Plugins'), findsOneWidget);
    // Metadata plugin with its versioned subtitle.
    expect(find.text('Goodreads Meta'), findsOneWidget);
    expect(find.text('v2.1 · Fetches metadata'), findsOneWidget);
    // Store plugin row.
    expect(find.text('Test Shop'), findsOneWidget);
    expect(
        find.text('Store plugin · Fake store plugin'), findsOneWidget);
  });

  testWidgets('removing a metadata plugin unloads it through the sidecar',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Only metadata rows carry a remove action; store rows have none.
    expect(find.byTooltip('Remove plugin'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove plugin'));
    await tester.pumpAndSettle();

    expect(sidecar.unloaded, ['Goodreads Meta']);
    expect(find.text('Goodreads Meta'), findsNothing);
    expect(find.text('Test Shop'), findsOneWidget);
    expect(state.plugins.metadataPlugins(), isEmpty);
    expect(state.plugins.storePlugins(), hasLength(1));
  });
}

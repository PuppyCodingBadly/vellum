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
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/library_page.dart';

void main() {
  late Directory tmp;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-library-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    state = AppState(
      config: VellumConfig(p.join(tmp.path, 'config.json')),
      library: library,
      engine: MetadataEngine(),
      plugins: PluginController(pluginDir: p.join(tmp.path, 'plugins')),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
    );
  });

  tearDown(() {
    state.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('a search with no hits says so instead of rendering nothing',
      (tester) async {
    await state.setSearchQuery('nonexistent');
    await tester.pumpWidget(AppStateScope(
      state: state,
      child: const MaterialApp(home: Scaffold(body: LibraryPage())),
    ));

    expect(find.text('No results for “nonexistent”.'), findsOneWidget);
  });

  testWidgets('an empty library explains itself when not searching',
      (tester) async {
    await tester.pumpWidget(AppStateScope(
      state: state,
      child: const MaterialApp(home: Scaffold(body: LibraryPage())),
    ));

    expect(find.text('No books in your library yet.'), findsOneWidget);
  });
}

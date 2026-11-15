/// Widget tests for [StatsPage]: seeded reading sessions render aggregated
/// totals, recent sessions and per-book stats.
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
import 'package:vellum/ui/stats_page.dart';
import '../support/test_support.dart';

void main() {
  late Directory tmp;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-stats-ui-');
    library = Library(p.join(tmp.path, 'library.db'));
    state = AppState(
      config: VellumConfig(p.join(tmp.path, 'config.json')),
      library: library,
      engine: MetadataEngine(),
      plugins: PluginController(
        pluginDir: p.join(tmp.path, 'plugins'),
        client: EmptySidecar(),
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
        child: const MaterialApp(home: Scaffold(body: StatsPage())),
      );

  testWidgets('seeded sessions render aggregated stats', (tester) async {
    final bookId = library.addBook(Book(
      title: 'Stats Book',
      authors: const ['Stats Author'],
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));
    // 3720s = 1h 2m and 300s = 5m; totals: 2 sessions, 4020s = 1h 7m.
    library.addReadingSession(
        bookId, '2026-10-26T09:00:00.000Z', 3720, 'epub:2');
    library.addReadingSession(
        bookId, '2026-10-27T18:30:00.000Z', 300, 'epub:3');

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.text('Reading Statistics'), findsOneWidget);

    // Summary cards: 4020s total, one book, two sessions.
    expect(find.text('Reading time'), findsOneWidget);
    expect(find.text('1h 7m'), findsOneWidget);
    expect(find.text('Books read'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // Recent sessions list shows the book and both durations.
    expect(find.text('Recent sessions'), findsOneWidget);
    expect(find.text('Stats Book'), findsWidgets);
    expect(find.textContaining('1h 2m'), findsOneWidget);
    expect(find.textContaining('5m'), findsOneWidget);

    // Per-book aggregation.
    expect(find.text('By book'), findsOneWidget);
    expect(find.textContaining('1h 7m · 2 sessions'), findsOneWidget);
  });

  testWidgets('the refresh button re-reads newly seeded sessions',
      (tester) async {
    final bookId = library.addBook(Book(
      title: 'Stats Book',
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));

    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.textContaining('No reading sessions yet'), findsOneWidget);

    library.addReadingSession(
        bookId, '2026-10-28T08:00:00.000Z', 60, 'epub:1');
    await tester.tap(find.byTooltip('Refresh statistics'));
    await tester.pump();

    // The summary and the recent-session row both report the same minute.
    expect(find.text('1m'), findsWidgets);
    expect(find.textContaining('No reading sessions yet'), findsNothing);
  });
}

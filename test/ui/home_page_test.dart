/// Widget tests for [HomePage]: library grid, search filtering and the
/// sort dropdown.
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
import 'package:vellum/ui/home_page.dart';
import 'package:vellum/ui/widgets/book_cover.dart';
import '../support/test_support.dart';

void main() {
  late Directory tmp;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-home-ui-');
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

  Book addBook(String title, List<String> authors) {
    final id = library.addBook(Book(
      title: title,
      authors: authors,
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));
    return library.getBook(id)!;
  }

  Widget wrap() => AppStateScope(
        state: state,
        child: const MaterialApp(home: HomePage()),
      );

  testWidgets('library renders and the search field filters the grid',
      (tester) async {
    addBook('Alpha Book', const ['Zed Writer']);
    addBook('Beta Book', const ['Amy Writer']);
    await state.refresh();

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.text('Alpha Book'), findsOneWidget);
    expect(find.text('Beta Book'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump(const Duration(milliseconds: 400)); // search debounce
    await tester.pump();

    expect(state.searchQuery, 'alpha');
    expect(find.text('Alpha Book'), findsOneWidget);
    expect(find.text('Beta Book'), findsNothing);
  });

  testWidgets('the sort dropdown reorders the grid and persists the key',
      (tester) async {
    addBook('Alpha Book', const ['Zed Writer']);
    addBook('Beta Book', const ['Amy Writer']);
    await state.refresh();

    await tester.pumpWidget(wrap());
    await tester.pump();

    List<String> titles() => tester
        .widgetList<BookCard>(find.byType(BookCard))
        .map((card) => card.book.title)
        .toList();

    // Default title sort.
    expect(titles(), ['Alpha Book', 'Beta Book']);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Author'));
    await tester.pumpAndSettle();

    expect(state.sortKey, 'author');
    expect(titles(), ['Beta Book', 'Alpha Book']);
    // The choice is persisted to the config file.
    final reloaded = VellumConfig(p.join(tmp.path, 'config.json'));
    expect(reloaded.getString('sort_key'), 'author');
  });
}

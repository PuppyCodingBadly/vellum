/// Widget tests for [ShelvesPage]: creating a shelf and adding a book to it.
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
import 'package:vellum/ui/shelves_page.dart';
import '../support/test_support.dart';

void main() {
  late Directory tmp;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-shelves-ui-');
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
        child: const MaterialApp(home: Scaffold(body: ShelvesPage())),
      );

  testWidgets('create a shelf, add a book, the book appears under the shelf',
      (tester) async {
    // Wide layout: shelf list beside the selected shelf's detail pane.
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bookId = library.addBook(Book(
      title: 'Shelf Book',
      authors: const ['Shelf Author'],
      formats: const ['epub'],
      path: '/nonexistent.epub',
    ));
    await state.refresh();

    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(find.text('No shelves yet'), findsWidgets);

    // Create the shelf.
    await tester.tap(find.text('New Shelf'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Favourites');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Favourites'), findsWidgets);
    // The wide layout auto-selects the first shelf and shows its (empty)
    // detail pane.
    expect(find.text('No books on this shelf'), findsOneWidget);

    // Add the seeded book through the picker dialog.
    await tester.tap(find.text('Add books…'));
    await tester.pumpAndSettle();
    expect(find.text('Add books'), findsOneWidget);
    await tester.tap(find.text('Shelf Book'));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    // The book appears under the shelf and the list badge updates.
    expect(find.text('Shelf Book'), findsOneWidget);
    expect(find.text('1 books'), findsOneWidget);
    final shelfId = library.listShelves().single['id'] as int;
    expect(
      library.shelfBooks(shelfId).map((book) => book.id),
      contains(bookId),
    );
  });

  testWidgets('an empty-name shelf is rejected instead of created',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.text('New Shelf'));
    await tester.pumpAndSettle();
    // Submit with an empty name: the dialog stays open and no shelf appears.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('New Shelf'), findsWidgets); // dialog still open
    expect(library.listShelves(), isEmpty);
  });
}

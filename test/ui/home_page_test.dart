/// Widget tests for [HomePage]: library grid, search filtering and the
/// sort dropdown.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/main.dart';
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
    final id = library.addBook(
      Book(
        title: title,
        authors: authors,
        formats: const ['epub'],
        path: '/nonexistent.epub',
      ),
    );
    return library.getBook(id)!;
  }

  Widget wrap() => AppStateScope(
    state: state,
    child: const MaterialApp(home: HomePage()),
  );

  testWidgets('library renders and the search field filters the grid', (
    tester,
  ) async {
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

  testWidgets('the sort dropdown reorders the grid and persists the key', (
    tester,
  ) async {
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

  testWidgets('Ctrl+F focuses the search field with Library already active', (
    tester,
  ) async {
    addBook('Alpha Book', const ['Zed Writer']);
    await state.refresh();

    await tester.pumpWidget(
      CallbackShortcuts(
        // Mirrors main.dart's builder: Ctrl+F calls the shell's focus owner.
        bindings: appShortcuts(
          focusSearch: () => tester
              .state<HomePageState>(find.byType(HomePage))
              .focusLibrarySearch(),
          toggleFullscreen: () {},
          quit: () {},
          back: () {},
        ),
        child: wrap(),
      ),
    );
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    // No extra frame: focusing must happen in the frame the shortcut fires,
    // not in a post-frame callback that nothing schedules.
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(state.searchQuery, 'alpha');
  });

  testWidgets('HomePage binds no app-wide shortcuts of its own', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pump();

    final triggers = <LogicalKeyboardKey>[
      for (final widget in tester.widgetList<CallbackShortcuts>(
        find.byType(CallbackShortcuts),
      ))
        for (final activator in widget.bindings.keys)
          if (activator is SingleActivator) activator.trigger,
    ];
    // F11 and Ctrl+Q live in main.dart's table, not here.
    expect(triggers, isNot(contains(LogicalKeyboardKey.f11)));
    expect(triggers, isNot(contains(LogicalKeyboardKey.keyQ)));
  });

  test('the app-wide shortcut table binds each action once', () {
    var focus = 0;
    var fullscreen = 0;
    var quit = 0;
    var back = 0;
    final bindings = appShortcuts(
      focusSearch: () => focus++,
      toggleFullscreen: () => fullscreen++,
      quit: () => quit++,
      back: () => back++,
    );

    List<SingleActivator> withTrigger(LogicalKeyboardKey key) => bindings.keys
        .whereType<SingleActivator>()
        .where((activator) => activator.trigger == key)
        .toList();

    final quitBindings = withTrigger(LogicalKeyboardKey.keyQ);
    expect(quitBindings, hasLength(1));
    expect(quitBindings.single.control, isTrue);
    bindings[quitBindings.single]!();
    expect(quit, 1);

    final focusBindings = withTrigger(LogicalKeyboardKey.keyF);
    expect(focusBindings, hasLength(1));
    expect(focusBindings.single.control, isTrue);
    bindings[focusBindings.single]!();
    expect(focus, 1);

    final fullscreenBindings = withTrigger(LogicalKeyboardKey.f11);
    expect(fullscreenBindings, hasLength(1));
    bindings[fullscreenBindings.single]!();
    expect(fullscreen, 1);

    final backBindings = withTrigger(LogicalKeyboardKey.arrowLeft);
    expect(backBindings, hasLength(1));
    expect(backBindings.single.alt, isTrue);
    bindings[backBindings.single]!();
    expect(back, 1);
  });
}

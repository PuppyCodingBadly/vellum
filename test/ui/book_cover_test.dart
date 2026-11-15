import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/cover_generator.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/cover_generator_dialog.dart';
import 'package:vellum/ui/widgets/book_cover.dart';
import 'package:vellum/ui/widgets/book_grid.dart';

void main() {
  late Directory tmp;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-cover-ui-');
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

  Book addBook(String coverPath) {
    final id = library.addBook(
      Book(
        title: 'Book',
        formats: ['epub'],
        path: '/b.epub',
        coverPath: coverPath,
      ),
    );
    return library.getBook(id)!;
  }

  Book addTitled(
    String title, {
    List<String> authors = const [],
    double progress = 0,
  }) {
    final id = library.addBook(
      Book(
        title: title,
        authors: authors,
        formats: const ['epub'],
        path: '/$title.epub',
      ),
    );
    // Reading positions live in their own table; the tests only need the value
    // the widgets read.
    return library.getBook(id)!.copyWith(progress: progress);
  }

  Widget wrap(Widget child) => AppStateScope(
    state: state,
    child: MaterialApp(home: Scaffold(body: child)),
  );

  /// A tile-sized box, so a lone [BookCard] lays out as it does in the grid.
  Widget card(Widget child) => SizedBox(
    width: 160,
    height: 160 * 1.5 + BookCard.captionExtent(TextScaler.noScaling),
    child: child,
  );

  Widget grid(List<Book> books, {double textScale = 1}) => AppStateScope(
    state: state,
    child: MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(body: BookGrid(books: books)),
        ),
      ),
    ),
  );

  /// Whether the card for [book] paints the hover/focus lift.
  bool lifted(WidgetTester tester, Book book) {
    final tile = find.byKey(ValueKey<Object>(book.id ?? book.path));
    final lift = tester.widget<AnimatedContainer>(
      find.descendant(of: tile, matching: find.byType(AnimatedContainer)).first,
    );
    return (lift.decoration as BoxDecoration?)?.boxShadow != null;
  }

  CoverRenderer fakeRenderer(Uint8List png, {List<Size>? renderSizes}) =>
      ({
        required String title,
        required String author,
        required String publisher,
        required CoverStyle style,
        required int width,
        required int height,
      }) async {
        renderSizes?.add(Size(width.toDouble(), height.toDouble()));
        return png;
      };

  Widget dialogHost(
    Book book,
    CoverRenderer renderer, {
    void Function(Uint8List? result)? onResult,
  }) => AppStateScope(
    state: state,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDialog<Uint8List>(
                  context: context,
                  builder: (_) =>
                      CoverGeneratorDialog(book: book, renderCover: renderer),
                );
                onResult?.call(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('real cover resolves through a background isolate', (
    tester,
  ) async {
    final coverPath = p.join(tmp.path, 'cover.png');
    File(
      coverPath,
    ).writeAsBytesSync(img.encodePng(img.Image(width: 60, height: 90)));
    final book = addBook(coverPath);

    await tester.runAsync(() async {
      await tester.pumpWidget(wrap(BookCover(book: book)));
      // Let the isolate thumbnail the cover, then rebuild with the result.
      for (var i = 0; i < 50 && find.byType(Image).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(find.byType(Image), findsOneWidget);
    final provider = tester.widget<Image>(find.byType(Image)).image;
    // `cacheWidth` wraps the provider in a ResizeImage.
    final fileImage = provider is ResizeImage
        ? provider.imageProvider as FileImage
        : provider as FileImage;
    expect(fileImage.file.path, endsWith('.png'));
  });

  testWidgets('missing cover falls back to the initials placeholder', (
    tester,
  ) async {
    final book = addBook(p.join(tmp.path, 'gone.png'));

    await tester.runAsync(() async {
      await tester.pumpWidget(wrap(BookCover(book: book)));
      for (var i = 0; i < 50 && find.text('B').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    // The placeholder text replaces the failed image inside its errorBuilder.
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('the progress rule fills to the read fraction', (tester) async {
    final book = addBook(p.join(tmp.path, 'gone.png')).copyWith(progress: 0.42);

    await tester.pumpWidget(wrap(BookCover(book: book)));
    await tester.pump();

    final rule = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(rule.widthFactor, closeTo(0.42, 1e-9));
  });

  testWidgets('an unread cover carries no progress rule', (tester) async {
    final book = addBook('');

    await tester.pumpWidget(wrap(BookCover(book: book)));
    await tester.pump();

    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('the grid keeps each tile state with its book across a reorder', (
    tester,
  ) async {
    final first = addTitled('First', authors: const ['Ada']);
    final second = addTitled('Second', authors: const ['Grace']);
    final firstTile = find.byKey(ValueKey<Object>(first.id!));
    final secondTile = find.byKey(ValueKey<Object>(second.id!));

    await tester.pumpWidget(grid([first, second]));
    await tester.pump();

    final firstState = tester.state(
      find.descendant(of: firstTile, matching: find.byType(BookCard)),
    );
    final secondState = tester.state(
      find.descendant(of: secondTile, matching: find.byType(BookCard)),
    );

    // A hovered tile carries state; it must not land on another book's tile.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(firstTile));
    await tester.pump();
    expect(lifted(tester, first), isTrue);

    await tester.pumpWidget(grid([second, first]));
    await tester.pump();

    // The elements, and the hover one of them holds, moved with their books
    // instead of staying in their slots and lighting up the swapped books.
    expect(
      tester.state(
        find.descendant(of: firstTile, matching: find.byType(BookCard)),
      ),
      same(firstState),
    );
    expect(
      tester.state(
        find.descendant(of: secondTile, matching: find.byType(BookCard)),
      ),
      same(secondState),
    );
  });

  testWidgets('a card reads as one label, not the visible text again', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final book = addTitled('Tile Book', authors: const ['Jane Doe']);

    await tester.pumpWidget(wrap(card(BookCard(book: book, onTap: () {}))));
    await tester.pump();

    expect(find.bySemanticsLabel(RegExp('Tile Book')), findsOneWidget);
    expect(find.bySemanticsLabel('Tile Book, by Jane Doe'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(BookCard));
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('the card label follows progressPercent and isFinished', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    final started = addTitled(
      'Started',
      authors: const ['Ada'],
      progress: 0.004,
    );
    await tester.pumpWidget(wrap(card(BookCard(book: started))));
    await tester.pump();
    // A hair past the start still reads as 1%, not as unopened.
    expect(find.bySemanticsLabel('Started, by Ada, 1% read'), findsOneWidget);

    final nearly = addTitled(
      'Nearly',
      authors: const ['Ada'],
      progress: 0.9985,
    );
    await tester.pumpWidget(wrap(card(BookCard(book: nearly))));
    await tester.pump();
    // Rounds to 100% but is not finished.
    expect(find.bySemanticsLabel('Nearly, by Ada, 100% read'), findsOneWidget);

    final done = addTitled('Done', authors: const ['Ada'], progress: 0.9999);
    await tester.pumpWidget(wrap(card(BookCard(book: done))));
    await tester.pump();
    expect(find.bySemanticsLabel('Done, by Ada, finished'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('grid captions fit at a large text scale', (tester) async {
    final books = [
      for (var i = 0; i < 4; i++)
        addTitled(
          'Tile $i',
          authors: const ['A Rather Long Author Name'],
          progress: 0.5,
        ),
    ];
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(grid(books, textScale: 1.3));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      BookCard.captionExtent(TextScaler.linear(1.3)),
      greaterThan(BookCard.captionExtent(TextScaler.noScaling)),
    );
  });

  testWidgets('Use Cover saves the artifact render and pops once', (
    tester,
  ) async {
    final png = img.encodePng(img.Image(width: 8, height: 12));
    final renderSizes = <Size>[];
    final results = <Uint8List?>[];
    final book = addTitled('Popup', authors: const ['Ada']);

    await tester.pumpWidget(
      dialogHost(
        book,
        fakeRenderer(png, renderSizes: renderSizes),
        onResult: results.add,
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pumpAndSettle();

    // One render, at the documented artifact size; the preview decodes it
    // down instead of the dialog rendering a second time.
    expect(renderSizes, [
      Size(kGeneratedCoverWidth.toDouble(), kGeneratedCoverHeight.toDouble()),
    ]);
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.text('Use Cover'));
    // A second tap in the same frame reaches the old callback; the dialog must
    // not pop its caller as well.
    await tester.tap(find.text('Use Cover'));
    await tester.pump();
    // While the dialog is on its way out, the button cannot fire again.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Use Cover'))
          .onPressed,
      isNull,
    );
    await tester.pumpAndSettle();

    expect(results, hasLength(1));
    expect(results.single, png);
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed render shows an error state and blocks saving', (
    tester,
  ) async {
    final png = img.encodePng(img.Image(width: 8, height: 12));
    var attempts = 0;
    final book = addTitled('Broken', authors: const ['Ada']);

    Future<Uint8List> flaky({
      required String title,
      required String author,
      required String publisher,
      required CoverStyle style,
      required int width,
      required int height,
    }) async {
      attempts++;
      if (attempts == 1) throw StateError('render failed');
      return png;
    }

    await tester.pumpWidget(dialogHost(book, flaky));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text("Couldn't draw the cover."), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Use Cover'))
          .onPressed,
      isNull,
    );

    // Retry resets the failure and re-enables saving.
    await tester.tap(find.text('Try Again'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.text("Couldn't draw the cover."), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Use Cover'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}

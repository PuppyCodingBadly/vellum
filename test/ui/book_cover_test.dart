import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/widgets/book_cover.dart';

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
    final id = library.addBook(Book(title: 'Book', formats: ['epub'], path: '/b.epub', coverPath: coverPath));
    return library.getBook(id)!;
  }

  Widget wrap(Widget child) =>
      AppStateScope(state: state, child: MaterialApp(home: Scaffold(body: child)));

  testWidgets('real cover resolves through a background isolate', (tester) async {
    final coverPath = p.join(tmp.path, 'cover.png');
    File(coverPath).writeAsBytesSync(
      img.encodePng(img.Image(width: 60, height: 90)),
    );
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

  testWidgets('missing cover falls back to the initials placeholder',
      (tester) async {
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
}

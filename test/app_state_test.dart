import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vellum/app_state.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/stats/reading_stats.dart';

void main() {
  late Directory root;
  late Library library;
  late AppState state;
  var stateDisposed = false;

  setUp(() {
    stateDisposed = false;
    root = Directory.systemTemp.createTempSync('vellum-app-state-');
    final first = Directory(p.join(root.path, 'first'))..createSync();
    library = Library(p.join(first.path, 'library.db'));
    state = AppState(
      config: VellumConfig(p.join(root.path, 'config.json')),
      library: library,
      engine: MetadataEngine(),
      plugins: PluginController(pluginDir: p.join(root.path, 'plugins')),
      fts: FtsIndexer(library),
      stats: ReadingStatsTracker(library),
    );
  });

  tearDown(() {
    if (!stateDisposed) state.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('switching is refused while a reader is open', () async {
    final second = Directory(p.join(root.path, 'second'))..createSync();

    state.registerReader();
    expect(state.hasOpenReaders, isTrue);
    expect(
      await state.switchLibraryDirectory(second.path),
      'Close the open book before switching libraries',
    );
    expect(identical(state.library, library), isTrue);
    expect(library.path, p.join(firstLibraryDir(root), 'library.db'));

    state.unregisterReader();
    expect(state.hasOpenReaders, isFalse);
    expect(await state.switchLibraryDirectory(second.path), isNull);
    expect(state.library.path, p.join(second.path, 'library.db'));
    // The replaced library is closed: stale handles fail loudly.
    expect(() => library.allBooks(), throwsStateError);
  });

  test('unregistering without a reader is harmless', () {
    state.unregisterReader();
    expect(state.hasOpenReaders, isFalse);
  });

  test('dispose closes the active library', () {
    final active = state.library;
    state.dispose();
    stateDisposed = true;

    expect(() => active.allBooks(), throwsStateError);
  });
}

String firstLibraryDir(Directory root) => p.join(root.path, 'first');

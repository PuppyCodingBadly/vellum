/// Plugin wiring tests: controller lifecycle, metadata dialog, store page.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/config.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';
import 'package:vellum/main.dart';
import 'package:vellum/metadata/engine.dart';
import 'package:vellum/metadata/metadata.dart';
import 'package:vellum/plugins/plugin_controller.dart';
import 'package:vellum/plugins/sidecar_client.dart';
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/widgets/book_cover.dart';

class _NoopSidecar extends SidecarClient {
  @override
  Future<void> dispose() async {}
}

class _RecordingSidecar extends _NoopSidecar {
  int loadAllCalls = 0;
  int loadCalls = 0;
  int unloadCalls = 0;
  int loadedCalls = 0;
  int metadataCalls = 0;
  final List<String> removed = [];

  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async {
    loadAllCalls++;
    return const LoadedPlugins(
      metadata: [PluginInfo(name: 'Fake Source', version: '1.0')],
      stores: [PluginInfo(name: 'Fake Store', version: '2.0')],
    );
  }

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async {
    loadedCalls++;
    return const LoadedPlugins(
      metadata: [PluginInfo(name: 'Fake Source', version: '1.0')],
      stores: [PluginInfo(name: 'Fake Store', version: '2.0')],
    );
  }

  @override
  Future<PluginLoadResult> load(String pluginDir, String zipPath) async {
    loadCalls++;
    return (
      kind: 'metadata',
      name: 'Fake Source',
      version: '1.0',
      description: 'Fake source',
    );
  }

  @override
  Future<bool> unload(String pluginDir, String name) async {
    unloadCalls++;
    removed.add(name);
    return true;
  }

  @override
  Future<List<Map<String, Object?>>> metadataSearch({
    String title = '',
    List<String>? authors,
    String isbn = '',
    double timeout = 15.0,
  }) async {
    metadataCalls++;
    return [
      <String, Object?>{
        'title': 'Plugin Book',
        'authors': ['Plugin Author'],
        'isbn': '9780306406157',
        'publisher': 'Plugin Press',
        'pubdate': '2020',
        'language': 'en',
        'description': 'From a calibre plugin.',
        'tags': ['plugin'],
        'rating': 4.5,
        'cover_url': '',
        'source_id': 'fakesrc',
        'source_name': 'Fake Source',
      },
    ];
  }
}

class _FakePlugins extends PluginController {
  _FakePlugins({
    this.metadataList = const [],
    this.storeList = const [],
    this.metadataRows = const [],
    this.storeRows = const [],
    this.download,
  }) : super(pluginDir: '/nonexistent', client: _NoopSidecar());

  final List<PluginInfo> metadataList;
  final List<PluginInfo> storeList;
  final List<Map<String, Object?>> metadataRows;
  final List<Map<String, Object?>> storeRows;
  final Map<String, Object?>? download;
  int metadataSearches = 0;
  int storeSearches = 0;

  @override
  Future<void> start() async {}

  @override
  List<PluginInfo> metadataPlugins() => metadataList;

  @override
  List<PluginInfo> storePlugins() => storeList;

  @override
  Future<List<Map<String, Object?>>> metadataSearch({
    String title = '',
    List<String>? authors,
    String isbn = '',
    double timeout = 15.0,
  }) async {
    metadataSearches++;
    return metadataRows;
  }

  @override
  Future<Uint8List?> downloadCover(Map<String, Object?> meta,
          {double timeout = 15.0}) async =>
      null;

  @override
  Future<List<Map<String, Object?>>> storeSearch(
    String store,
    String query, {
    int maxResults = 10,
    double timeout = 60.0,
  }) async {
    storeSearches++;
    return storeRows;
  }

  @override
  Future<Map<String, Object?>?> storeFetchDownload(
    String store,
    Map<String, Object?> result, {
    double timeout = 60.0,
  }) async =>
      download;
}

Widget _app(
  VellumConfig config,
  Library library,
  PluginController plugins,
) {
  return VellumApp(
    config: config,
    library: library,
    engine: MetadataEngine(),
    plugins: plugins,
    fts: FtsIndexer(library),
    stats: ReadingStatsTracker(library),
  );
}

void main() {
  test('PluginController starts once, notifies, and guards async calls',
      () async {
    final sidecar = _RecordingSidecar();
    final plugins = PluginController(pluginDir: '/tmp/none', client: sidecar);
    var notifications = 0;
    plugins.addListener(() => notifications++);

    await Future.wait([plugins.start(), plugins.start(), plugins.start()]);
    expect(sidecar.loadAllCalls, 1);
    expect(plugins.metadataPlugins().single.name, 'Fake Source');
    expect(plugins.storePlugins().single.name, 'Fake Store');
    expect(notifications, 1);

    final rows = await plugins.metadataSearch(title: 'x');
    expect(sidecar.metadataCalls, 1);
    expect(rows.single['title'], 'Plugin Book');

    await plugins.addPlugin('/tmp/fake.zip');
    expect(sidecar.loadCalls, 1);
    expect(sidecar.loadedCalls, 1);
    expect(notifications, 2);

    await plugins.removePlugin('Fake Source');
    expect(sidecar.unloadCalls, 1);
    expect(sidecar.removed, ['Fake Source']);

    plugins.dispose();
  });

  test('combineSources and combineQuery merge plugin results', () {
    final builtIn = Metadata(
      title: 'Dune',
      authors: const ['Frank Herbert'],
      isbn: '9780441013593',
      publisher: 'Chilton',
      description: 'A short description.',
      rating: 4.0,
      sourceId: 'ol',
      sourceName: 'OpenLibrary',
    );
    final plugin = Metadata(
      title: 'Dune',
      authors: const ['Frank Herbert'],
      isbn: '9780132350884',
      description: 'A much longer plugin description.',
      rating: 5.0,
      sourceId: 'fakesrc',
      sourceName: 'Fake Source',
    );

    final combined = MetadataEngine.combineSources([builtIn, plugin]);
    expect(combined.first.sourceId, 'merged');
    expect(combined.length, 3);
    expect(combined.where((m) => m.sourceId == 'ol').length, 1);
    expect(combined.first.description, 'A much longer plugin description.');

    final ranked = MetadataEngine.combineQuery('dune frank herbert', [
      Metadata(title: 'Cooking', rating: 5.0, sourceId: 'x'),
      builtIn,
      plugin,
    ]);
    expect(ranked.first.sourceId, 'merged');
    expect(ranked[1].title, 'Dune');
  });

  testWidgets('metadata dialog searches and applies plugin results',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('vellum-plugin-meta-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final library = Library('${dir.path}/library.db');
    addTearDown(library.close);
    final book = Book(title: 'Original Title');
    library.addBook(book);

    final plugins = _FakePlugins(
      metadataList: const [
        PluginInfo(name: 'Fake Source', version: '1.0'),
      ],
      metadataRows: [
        <String, Object?>{
          'title': 'Plugin Book',
          'authors': ['Plugin Author'],
          'isbn': '9780306406157',
          'publisher': 'Plugin Press',
          'pubdate': '2020',
          'language': 'en',
          'description': 'From a calibre plugin.',
          'tags': ['plugin'],
          'rating': 4.5,
          'cover_url': '',
          'source_id': 'fakesrc',
          'source_name': 'Fake Source',
        },
      ],
    );

    await tester.pumpWidget(
        _app(VellumConfig('${dir.path}/config.json'), library, plugins));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BookCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch Metadata'));
    await tester.pumpAndSettle();

    expect(plugins.metadataSearches, 1);
    expect(find.text('Plugin Book'), findsOneWidget);
    expect(find.textContaining('Fake Source'), findsOneWidget);

    await tester.tap(find.text('Plugin Book'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    final updated = library.getBook(book.id!);
    expect(updated!.title, 'Plugin Book');
    expect(updated.authors, ['Plugin Author']);
    expect(updated.rating, 4.5);
    expect(updated.publisher, 'Plugin Press');
  });

  testWidgets('Get Books searches and downloads through store plugins',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('vellum-plugin-store-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final library = Library('${dir.path}/library.db');
    addTearDown(library.close);

    final plugins = _FakePlugins(
      storeList: const [
        PluginInfo(name: 'Fake Store', version: '2.0', description: 'Store'),
      ],
      storeRows: [
        <String, Object?>{
          'title': 'Dune',
          'author': 'Frank Herbert',
          'formats': 'EPUB',
          'detail_item': 'item-1',
          'cover_url': '',
          'download_url': '',
          'store_name': 'Fake Store',
        },
      ],
      download: null,
    );

    await tester.pumpWidget(
        _app(VellumConfig('${dir.path}/config.json'), library, plugins));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Get Books'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Search stores…'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'dune');
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(plugins.storeSearches, 1);
    expect(find.text('Dune'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Could not resolve download link'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  test('real sidecar loads metadata and store plugins end to end', () async {
    final dir = Directory.systemTemp.createTempSync('vellum-plugin-sidecar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final pluginDir = Directory('${dir.path}/plugins')..createSync();
    _writeZip('${pluginDir.path}/fakesrc.zip', {
      'plugin-import-name-fakesrc.txt': 'fakesrc',
      'fakesrc/__init__.py': r'''
from calibre.ebooks.metadata.sources.base import Source
from calibre.ebooks.metadata.book.base import Metadata as CalibreMetadata


class FakeSource(Source):
    name = "Fake Source"
    id = "fakesrc"
    version = (1, 0, 0)
    description = "Fake calibre metadata source for tests."
    capabilities = frozenset({"identify"})

    def search(self, title="", authors=None, isbn="", timeout=15.0):
        results = []
        for t, i in (("Fake Book One", "9780306406157"),
                     ("Fake Book Two", "9780132350884")):
            m = CalibreMetadata(t, ["Test Author"])
            m.set_identifier("isbn", i)
            m.publisher = "Fake Publisher"
            m.tags = ["fake"]
            results.append(m)
        return results

    def identify(self, log, result_queue, abort, title=None, authors=None,
                 identifiers=None, timeout=30):
        for m in self.search(title=title or ""):
            result_queue.put(m)
''',
    });
    _writeZip('${pluginDir.path}/store_x.zip', {
      'plugin-import-name-store_x.txt': 'store_x',
      'store_x/__init__.py': r'''
from calibre.customize import Plugin


class StoreX(Plugin):
    name = "Store X"
    description = "Fake store plugin for tests."
''',
      'store_x/search.py': r'''
class _Hit:
    def __init__(self, title, author):
        self.title = title
        self.author = author
        self.formats = "EPUB"
        self.detail_item = "item-1"
        self.cover_url = "http://example.invalid/cover.jpg"


def search_libgen(query, max_results=10, timeout=60.0):
    return [_Hit("Store Hit: " + query, "Store Author")]
''',
    });

    final plugins = PluginController(pluginDir: pluginDir.path);
    try {
      await plugins.start();
      expect(plugins.metadataPlugins().map((p) => p.name),
          contains('Fake Source'));
      expect(plugins.storePlugins().map((p) => p.name), contains('Store X'));

      final metadata = await plugins.metadataSearch(title: 'x');
      expect(
        metadata.map((m) => m['title']),
        containsAll(<String>['Fake Book One', 'Fake Book Two']),
      );
      expect(metadata.map((m) => m['source_name']), everyElement('Fake Source'));

      final store = await plugins.storeSearch('Store X', 'dune');
      expect(store.single['title'], 'Store Hit: dune');
      expect(store.single['store_name'], 'Store X');
    } finally {
      await plugins.client.dispose();
      plugins.dispose();
    }
  });
}

void _writeZip(String path, Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
}

/// Widget tests for [PreferencesDialog]: toggling preferences persists them
/// to the config file and a reopened dialog reflects the stored values.
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
import 'package:vellum/stats/reading_stats.dart';
import 'package:vellum/ui/preferences_dialog.dart';
import '../support/test_support.dart';

void main() {
  late Directory tmp;
  late String configPath;
  late Library library;
  late AppState state;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-prefs-ui-');
    configPath = p.join(tmp.path, 'config.json');
    library = Library(p.join(tmp.path, 'library.db'));
    state = AppState(
      config: VellumConfig(configPath),
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
        child: const MaterialApp(home: Scaffold(body: PreferencesDialog())),
      );

  testWidgets('toggling preferences persists them and reopening reflects them',
      (tester) async {
    // Give the dialog room so every section is visible without scrolling.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrap());
    await tester.pump();

    // Defaults from a fresh config.
    final segments =
        tester.widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    expect(segments.selected, {'system'});
    expect(
      tester
          .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Show hidden books'))
          .value,
      isFalse,
    );

    // Toggle: dark scheme, hidden books shown, page animation off.
    await tester.tap(find.text('Dark'));
    await tester.pump();
    await tester.tap(find.widgetWithText(SwitchListTile, 'Show hidden books'));
    await tester.pump();
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Page turn animation'));
    await tester.pump();

    // Each change was written through to the config file on disk.
    final reloaded = VellumConfig(configPath);
    expect(reloaded.getString('color_scheme'), 'dark');
    expect(reloaded.getBool('show_hidden'), isTrue);
    expect(reloaded.getBool('reader_animation'), isFalse);

    // A freshly opened dialog reflects the persisted values.
    await tester.pumpWidget(wrap());
    await tester.pump();
    final reopened = tester
        .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>));
    expect(reopened.selected, {'dark'});
    expect(
      tester
          .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Show hidden books'))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Page turn animation'))
          .value,
      isFalse,
    );
  });
}

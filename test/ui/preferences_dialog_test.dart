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
import 'package:vellum/ui/theme.dart';
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

  Widget wrap({DirectoryPicker? chooseDirectory}) => AppStateScope(
    state: state,
    child: MaterialApp(
      scaffoldMessengerKey: state.messengerKey,
      home: Scaffold(
        body: chooseDirectory == null
            ? const PreferencesDialog()
            : PreferencesDialog(chooseDirectory: chooseDirectory),
      ),
    ),
  );

  testWidgets(
    'toggling preferences persists them and reopening reflects them',
    (tester) async {
      // Give the dialog room so every section is visible without scrolling.
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(wrap());
      await tester.pump();

      // Defaults from a fresh config.
      final segments = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(segments.selected, {'system'});
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Show hidden books'),
            )
            .value,
        isFalse,
      );

      // Toggle: dark scheme, hidden books shown, page animation off.
      await tester.tap(find.text('Dark'));
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Show hidden books'),
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(SwitchListTile, 'Page turn animation'),
      );
      await tester.pump();

      // Each change was written through to the config file on disk.
      final reloaded = VellumConfig(configPath);
      expect(reloaded.getString('color_scheme'), 'dark');
      expect(reloaded.getBool('show_hidden'), isTrue);
      expect(reloaded.getBool('reader_animation'), isFalse);

      // A freshly opened dialog reflects the persisted values.
      await tester.pumpWidget(wrap());
      await tester.pump();
      final reopened = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(reopened.selected, {'dark'});
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Show hidden books'),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Page turn animation'),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets('a refused library switch shows the switch error verbatim', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // An open reader makes AppState refuse the switch with its own message.
    state.registerReader();
    final target = p.join(tmp.path, 'other-library');
    await tester.pumpWidget(
      wrap(
        chooseDirectory: ({initialDirectory, confirmButtonText}) async =>
            target,
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Choose…'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Close the open book before switching libraries'),
      findsOneWidget,
    );
    expect(find.text('Cannot use that directory'), findsNothing);
    expect(state.libraryDir, isNot(target));
  });

  testWidgets('a light custom accent is checkmarked with the label ink', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // `#66cc99` has luminance below 0.5, so the old threshold drew white; the
    // WCAG label check (white fails 4.5:1 on it) draws black.
    const custom = Color(0xFF66CC99);
    state.setAccentColor('#66cc99');
    await tester.pumpWidget(wrap());
    await tester.pump();

    final check = tester.widget<Icon>(find.byIcon(Icons.check));
    expect(check.color, Colors.black);
    expect(
      check.color,
      VellumPalette.forMode(Brightness.light, custom).onAccent,
    );
  });
}

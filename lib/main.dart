/// Vellum application entry point.
///
/// Ports the application shell of `vellum/app.py`: window setup, service
/// construction, the one-shot legacy demo purge and the root widget.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'core/config.dart';
import 'core/db.dart';
import 'fts/indexer.dart';
import 'metadata/engine.dart';
import 'metadata/sources/google_books.dart';
import 'metadata/sources/internet_archive.dart';
import 'metadata/sources/inventaire.dart';
import 'metadata/sources/library_of_congress.dart';
import 'metadata/sources/openlibrary.dart';
import 'plugins/plugin_controller.dart';
import 'stats/reading_stats.dart';
import 'ui/home_page.dart';

/// Boots the services and starts the Flutter application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  unawaited(windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Vellum',
      size: Size(1100, 750),
      minimumSize: Size(480, 600),
      center: true,
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  ));

  final dataDir = VellumConfig.dataDir();
  Directory(dataDir).createSync(recursive: true);
  Directory(p.join(dataDir, 'covers')).createSync(recursive: true);
  final pluginDir = p.join(dataDir, 'plugins');
  Directory(pluginDir).createSync(recursive: true);

  final config = VellumConfig(p.join(dataDir, 'config.json'));
  final configured = config.get('library_path');
  final configuredPath = configured is String && configured.isNotEmpty
      ? configured
      : p.join(dataDir, 'library.db');
  String? pendingToast;
  Library library;
  try {
    library = Library(configuredPath);
  } catch (error) {
    debugPrint('Vellum: could not open $configuredPath: $error');
    pendingToast =
        'Could not open $configuredPath; using the default library';
    library = Library(p.join(dataDir, 'library.db'));
  }

  final engine = MetadataEngine()
    ..registerSource(GoogleBooks())
    ..registerSource(OpenLibrary())
    ..registerSource(InternetArchive())
    ..registerSource(LibraryOfCongress())
    ..registerSource(Inventaire());

  final plugins = PluginController(pluginDir: pluginDir);
  unawaited(() async {
    try {
      await plugins.start();
    } catch (error) {
      debugPrint('Vellum: plugin sidecar failed to start: $error');
    }
  }());

  final fts = FtsIndexer(library);
  final stats = ReadingStatsTracker(library);

  if (!config.getBool('legacy_demo_books_purged')) {
    try {
      library.deleteBooksWithoutFiles({
        'The Left Hand of Darkness',
        'Pride and Prejudice',
        'The Hobbit',
        'Clean Code',
        'Dune',
      });
    } catch (error) {
      debugPrint('Vellum: legacy demo book purge failed: $error');
    } finally {
      config.set('legacy_demo_books_purged', true);
    }
  }

  runApp(
    VellumApp(
      config: config,
      library: library,
      engine: engine,
      plugins: plugins,
      fts: fts,
      stats: stats,
      pendingToast: pendingToast,
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(() async {
      try {
        await fts.indexAll();
      } catch (error) {
        debugPrint('Vellum: full-text indexing failed: $error');
      }
    }());
  });
}

/// Root widget: owns the [AppState] and builds the Material application.
class VellumApp extends StatefulWidget {
  const VellumApp({
    super.key,
    required this.config,
    required this.library,
    required this.engine,
    required this.plugins,
    required this.fts,
    required this.stats,
    this.pendingToast,
  });

  final VellumConfig config;
  final Library library;
  final MetadataEngine engine;
  final PluginController plugins;
  final FtsIndexer fts;
  final ReadingStatsTracker stats;

  /// Toast shown once after the first frame (for example a library fallback).
  final String? pendingToast;

  @override
  State<VellumApp> createState() => _VellumAppState();
}

class _VellumAppState extends State<VellumApp> {
  late final AppState _state;

  /// Navigator used by the app-wide shortcuts to pop pushed routes.
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// Reaches the [HomePage] so Ctrl+F can focus the library search from any
  /// route.
  final GlobalKey<HomePageState> _homeKey = GlobalKey<HomePageState>();

  void _focusLibrarySearch() {
    // Pop any pushed routes so the HomePage (and its search field) is visible.
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _homeKey.currentState?.focusLibrarySearch();
  }

  @override
  void initState() {
    super.initState();
    _state = AppState(
      config: widget.config,
      library: widget.library,
      engine: widget.engine,
      plugins: widget.plugins,
      fts: widget.fts,
      stats: widget.stats,
    );
    unawaited(() async {
      try {
        await _state.refresh();
      } catch (error) {
        debugPrint('Vellum: initial library refresh failed: $error');
      }
    }());
    final toast = widget.pendingToast;
    if (toast != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _state.showToast(toast);
      });
    }
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  Future<void> _quit() async {
    try {
      await windowManager.destroy();
    } catch (error) {
      debugPrint('Vellum: quit failed: $error');
    }
  }

  ThemeData _theme(Color accent, Brightness brightness) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) => MaterialApp(
          title: 'Vellum',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _state.messengerKey,
          navigatorKey: _navigatorKey,
          themeMode: _state.themeMode,
          theme: _theme(_state.accentColor, Brightness.light),
          darkTheme: _theme(_state.accentColor, Brightness.dark),
          builder: (context, child) => CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
                  _quit,
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _focusLibrarySearch,
              const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
                  () => _navigatorKey.currentState?.maybePop(),
            },
            child: child ?? const SizedBox.shrink(),
          ),
          home: _TitleBarTheme(child: HomePage(key: _homeKey)),
        ),
      ),
    );
  }
}

/// Keeps the GTK client-side title bar in step with the Material brightness.
///
/// Linux has no Flutter-level API for the window decoration, so the runner
/// listens on `io.github.vellum/window` and flips
/// `gtk-application-prefer-dark-theme`.
class _TitleBarTheme extends StatefulWidget {
  const _TitleBarTheme({required this.child});

  final Widget child;

  @override
  State<_TitleBarTheme> createState() => _TitleBarThemeState();
}

class _TitleBarThemeState extends State<_TitleBarTheme> {
  static const MethodChannel _channel =
      MethodChannel('io.github.vellum/window');

  bool? _dark;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark == _dark) return;
    _dark = dark;
    unawaited(
      _channel.invokeMethod<void>('setDarkTitleBar', dark).catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

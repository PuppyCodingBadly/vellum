/// Central application state for the Vellum Flutter port.
///
/// Implements the shared UI contract in `docs/inventory/ui_contract.md`:
/// library view state, appearance, reader preferences, toasts and calibre
/// import. Pages access the instance with [AppState.of]; [AppStateScope]
/// publishes it through an [InheritedNotifier] so every page rebuilds when
/// state changes.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'core/config.dart';
import 'core/db.dart';
import 'core/models.dart';
import 'core/sorting.dart';
import 'fts/indexer.dart';
import 'import/calibre.dart';
import 'metadata/engine.dart';
import 'plugins/plugin_controller.dart';
import 'stats/reading_stats.dart';

/// Central application state. Provided via [AppStateScope] and read with
/// [AppState.of].
class AppState extends ChangeNotifier {
  AppState({
    required this.config,
    required this.library,
    required this.engine,
    required this.plugins,
    required this.fts,
    required this.stats,
  }) {
    plugins.addListener(notifyListeners);
  }

  /// Detaches from the plugin controller and shuts the sidecar down.
  @override
  void dispose() {
    plugins.removeListener(notifyListeners);
    plugins.dispose();
    super.dispose();
  }

  final VellumConfig config;

  /// The open library database; replaced when the library directory changes.
  Library library;
  final MetadataEngine engine;
  final PluginController plugins;
  /// Full-text indexer bound to the current [library]; recreated on switch.
  FtsIndexer fts;

  /// Reading-stats tracker bound to the current [library]; recreated on
  /// switch.
  ReadingStatsTracker stats;

  /// Root scaffold messenger used by [showToast]; installed on `MaterialApp`.
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// `~/.local/share/vellum` (XDG-aware).
  String get dataDir => VellumConfig.dataDir();

  /// Directory containing the current `library.db`.
  String get libraryDir => library.baseDir;

  // --- library view state ---

  /// Current view: the search hits (or all books) in the selected sort order.
  List<Book> books = <Book>[];

  /// Raw search query typed by the user.
  String searchQuery = '';

  /// Configured sort key; see [SORT_OPTIONS].
  String get sortKey {
    final key = config.getString('sort_key');
    return SORT_KEYS.contains(key) ? key : 'title';
  }

  /// Whether hidden books are shown in the grid.
  bool get showHidden => config.getBool('show_hidden');

  /// Re-queries the database with the current query, sort and hidden filter.
  Future<void> refresh() async {
    final includeHidden = showHidden;
    final query = searchQuery.trim();
    final found = query.isEmpty
        ? library.allBooks(includeHidden: includeHidden)
        : library.search(searchQuery, includeHidden: includeHidden);
    books = sortBooks(found, key: sortKey);
    notifyListeners();
  }

  /// Sets the active search query and refreshes the view.
  Future<void> setSearchQuery(String q) async {
    if (q == searchQuery) return;
    searchQuery = q;
    await refresh();
  }

  /// Persists the sort key and refreshes the view.
  Future<void> setSortKey(String key) async {
    if (!SORT_KEYS.contains(key)) return;
    config.set('sort_key', key);
    await refresh();
  }

  /// Persists the hidden-books preference and refreshes the view.
  Future<void> setShowHidden(bool v) async {
    config.set('show_hidden', v);
    await refresh();
  }

  /// Hides or unhides [book] and refreshes the view.
  Future<void> setBookHidden(Book book, bool hidden) async {
    final id = book.id;
    if (id == null) return;
    library.setHidden(id, hidden);
    await refresh();
  }

  /// Looks up a book by database id.
  Book? bookById(int id) => library.getBook(id);

  /// Searches indexed book contents; rows are
  /// `{book_id, chapter, title, snippet}`.
  List<Map<String, Object?>> searchBookContents(String q) =>
      fts.search(q);

  // --- library switching ---

  /// Switches to the library database inside [dir].
  ///
  /// Validates that [dir] exists (creating it if necessary) and is writable,
  /// opens `<dir>/library.db` and only then replaces the current library.
  /// Returns null on success or an error message on failure; on failure the
  /// previous library stays active.
  Future<String?> switchLibraryDirectory(String dir) async {
    final target = dir.trim();
    if (target.isEmpty) return 'No directory selected';
    Library? opened;
    try {
      Directory(target).createSync(recursive: true);
      final probe = File(p.join(target, '.vellum-write-test'));
      probe.writeAsStringSync('');
      probe.deleteSync();
      opened = Library(p.join(target, 'library.db'));
      config.set('library_path', opened.path);
    } catch (error) {
      opened?.close();
      return 'Cannot use that directory: $error';
    }
    final previous = library;
    library = opened;
    try {
      previous.close();
    } catch (_) {
      // The old connection is already unreachable; ignore close failures.
    }
    // Rebind services to the new library so searches and stats hit the new
    // database instead of the replaced one.
    fts = FtsIndexer(opened);
    stats = ReadingStatsTracker(opened);
    await refresh();
    return null;
  }

  // --- appearance ---

  /// Theme mode implied by the `color_scheme` setting.
  ThemeMode get themeMode {
    switch (config.getString('color_scheme')) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  /// Resolved accent colour (palette name or `#rrggbb`).
  Color get accentColor => resolveAccent(accentName);

  /// Raw `accent_color` setting.
  String get accentName => config.getString('accent_color');

  /// Persists `color_scheme` (`system`|`light`|`dark`).
  void setColorScheme(String scheme) {
    if (!const {'system', 'light', 'dark'}.contains(scheme)) return;
    config.set('color_scheme', scheme);
    notifyListeners();
  }

  /// Persists the accent colour (palette name or `#rrggbb`).
  void setAccentColor(String accent) {
    final value = accent.trim();
    if (value.isEmpty) return;
    config.set('accent_color', value);
    notifyListeners();
  }

  // --- reader prefs ---

  /// Whether reader page-turn animation is enabled.
  bool get readerAnimation => config.getBool('reader_animation');

  set readerAnimation(bool v) {
    config.set('reader_animation', v);
    notifyListeners();
  }

  /// Reader font scale, clamped to 0.8–1.6 and rounded to one decimal.
  double get readerFontScale {
    final value = config.getDouble('reader_font_scale').clamp(0.8, 1.6);
    return (value * 10).round() / 10;
  }

  set readerFontScale(double v) {
    final clamped = (v.clamp(0.8, 1.6) * 10).round() / 10;
    config.set('reader_font_scale', clamped);
    notifyListeners();
  }

  /// Reader theme: `follow`|`light`|`sepia`|`dark`.
  String get readerTheme {
    final value = config.getString('reader_theme');
    return _readerThemes.contains(value) ? value : 'follow';
  }

  set readerTheme(String v) {
    if (!_readerThemes.contains(v)) return;
    config.set('reader_theme', v);
    notifyListeners();
  }

  static const Set<String> _readerThemes = {'follow', 'light', 'sepia', 'dark'};

  // --- toasts ---

  /// Shows a three-second snackbar. Safe to call from anywhere under the app.
  void showToast(String message) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  // --- calibre import ---

  bool _calibreImportRunning = false;

  /// True while [chooseAndImportCalibre] is importing.
  bool get calibreImportRunning => _calibreImportRunning;

  /// Asks for a calibre library folder and imports it into the current library.
  Future<void> chooseAndImportCalibre() async {
    if (_calibreImportRunning) {
      showToast('A calibre import is already running');
      return;
    }
    // file_selector exposes no dialog title on Linux; the confirmation label
    // carries the GTK dialog's "Choose Calibre Library Folder" wording.
    String? folder;
    try {
      folder = await getDirectoryPath(
        confirmButtonText: 'Choose Calibre Library Folder',
      );
    } catch (_) {
      return; // Dialog cancelled or unavailable.
    }
    if (folder == null || folder.isEmpty) return;
    if (!isCalibreLibrary(folder)) {
      showToast('Not a calibre library (no metadata.db)');
      return;
    }
    if (_calibreImportRunning) {
      showToast('A calibre import is already running');
      return;
    }
    _calibreImportRunning = true;
    showToast('Importing calibre library…');
    await WidgetsBinding.instance.endOfFrame;
    try {
      final result = await importCalibreLibrary(library, folder);
      await refresh();
      final parts = <String>[
        'Imported ${result.added} calibre '
            '${result.added == 1 ? 'book' : 'books'}',
      ];
      if (result.skipped > 0) {
        parts.add('${result.skipped} already present');
      }
      if (result.failed > 0) {
        final runes = result.firstError.runes;
        final detail = String.fromCharCodes(runes.take(140));
        parts.add(
          '${result.failed} failed'
          '${result.firstError.isEmpty ? '' : ': $detail'}'
          '${runes.length > 140 ? '…' : ''}',
        );
      }
      showToast(parts.join(' · '));
    } catch (error) {
      showToast('Calibre import failed: $error');
    } finally {
      _calibreImportRunning = false;
    }
  }

  // --- accent palette ---

  /// Named accent colours from the GTK palette.
  static const Map<String, Color> accentPalette = {
    'blue': Color(0xFF3584E4),
    'teal': Color(0xFF2190A4),
    'green': Color(0xFF3A944A),
    'yellow': Color(0xFFC88800),
    'orange': Color(0xFFED5B00),
    'red': Color(0xFFE62D42),
    'pink': Color(0xFFD56199),
    'purple': Color(0xFF9141AC),
    'slate': Color(0xFF6F8396),
  };

  static final RegExp _hexPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// Resolves a palette name or `#rrggbb` string; unknown values are blue.
  static Color resolveAccent(String nameOrHex) {
    final value = nameOrHex.trim();
    if (_hexPattern.hasMatch(value)) {
      return Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
    }
    return accentPalette[value] ?? accentPalette['blue']!;
  }

  /// Finds the state published by [AppStateScope]; throws when absent.
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    if (scope == null) {
      throw FlutterError(
        'AppState.of() called with a context that has no AppStateScope '
        'ancestor.',
      );
    }
    return scope.state;
  }
}

/// Publishes an [AppState] to the widget tree and rebuilds dependents when it
/// notifies.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState state,
    required super.child,
  }) : super(notifier: state);

  /// The exposed state.
  AppState get state => notifier!;
}

# UI shared contract — AppState and navigation

All UI slices code against this exact API. `lib/app_state.dart` is owned by the Shell agent; other UI agents MUST NOT create or modify it.

```dart
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/db.dart';
import '../core/config.dart';
import '../metadata/engine.dart';
import '../plugins/plugin_controller.dart';
import '../fts/indexer.dart';
import '../stats/reading_stats.dart';

/// Central application state. Provided via InheritedWidget/ChangeNotifier;
/// access with `AppState.of(context)`.
class AppState extends ChangeNotifier {
  AppState({required this.config, required this.library, required this.engine,
      required this.plugins, required this.fts, required this.stats});

  final VellumConfig config;
  Library library;                    // replaced on library-directory switch
  final MetadataEngine engine;
  final PluginController plugins;
  final FtsIndexer fts;
  final ReadingStatsTracker stats;

  String get dataDir;                 // ~/.local/share/vellum (XDG-aware)
  String get libraryDir;              // dir containing the current library.db

  // --- library view state ---
  List<Book> books = [];              // current view: search + sort + hidden applied
  String searchQuery = '';
  String get sortKey;                 // config['sort_key']
  bool get showHidden;                // config['show_hidden']
  Future<void> refresh();             // re-query db with current query/sort/hidden, notify
  Future<void> setSearchQuery(String q);
  Future<void> setSortKey(String key);    // persists config
  Future<void> setShowHidden(bool v);     // persists config + refresh
  Future<void> setBookHidden(Book b, bool hidden);  // db + refresh

  // --- library switching ---
  /// Returns null on success, error message on failure (rollback performed).
  Future<String?> switchLibraryDirectory(String dir);

  // --- appearance ---
  ThemeMode get themeMode;            // from config color_scheme system/light/dark
  Color get accentColor;              // resolved accent (palette name or #rrggbb)
  String get accentName;              // raw config value
  void setColorScheme(String scheme); // 'system'|'light'|'dark', persists + notify
  void setAccentColor(String accent); // palette name or '#rrggbb', persists + notify

  // --- reader prefs ---
  bool get readerAnimation;
  set readerAnimation(bool v);        // persists
  double get readerFontScale;         // 0.8–1.6
  set readerFontScale(double v);      // persists, clamped
  String get readerTheme;             // 'follow'|'light'|'sepia'|'dark'
  set readerTheme(String v);          // persists

  // --- toasts ---
  /// Shows a 3-second snackbar. Safe to call from anywhere under MaterialApp.
  void showToast(String message);

  // --- accent palette ---
  static const Map<String, Color> accentPalette = {
    'blue': Color(0xFF3584E4), 'teal': Color(0xFF2190A4),
    'green': Color(0xFF3A944A), 'yellow': Color(0xFFC88800),
    'orange': Color(0xFFED5B00), 'red': Color(0xFFE62D42),
    'pink': Color(0xFFD56199), 'purple': Color(0xFF9141AC),
    'slate': Color(0xFF6F8396),
  };
  static Color resolveAccent(String nameOrHex); // '#rrggbb' or palette name

  static AppState of(BuildContext context); // throws if absent
}
```

## Navigation
MaterialApp with a root `HomePage` (tabs: Library, Shelves, Get Books, Plugins, Stats — NavigationRail on wide, bottom NavigationBar when narrow). Pushed routes via `Navigator.of(context).push(MaterialPageRoute(...))` for BookDetailsPage and ReaderPage. No custom stack. Ctrl+F focuses library search; Alt+Left pops; F11 fullscreen (window_manager); Ctrl+Q quits. Window title "Vellum", initial size ~1100×750.

## Toasts
`appState.showToast(msg)` — 3 s SnackBar equivalent of Adw.Toast.

## Config
`VellumConfig` at `<dataDir>/config.json`, keys/defaults per inventory/ui.md §0. `VellumConfig.dataDir()` honors XDG_DATA_HOME.

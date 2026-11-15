/// Root application shell: a library rail, the active page, and the menu.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import 'library_page.dart';
import 'plugins_page.dart';
import 'preferences_dialog.dart';
import 'shelves_page.dart';
import 'stats_page.dart';
import 'store_page.dart';
import 'theme.dart';

/// Application home: five destinations in a rail (or bottom bar when narrow)
/// and the currently selected page.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  static const int _libraryTab = 0;

  int _tabIndex = _libraryTab;

  /// Reaches the library's search field for the app-level Ctrl+F shortcut.
  final GlobalKey<LibraryPageState> _libraryKey = GlobalKey<LibraryPageState>();

  void _selectTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
  }

  /// Switches to the Library tab and focuses the search field.
  ///
  /// The only owner of search focus; called from the app-wide Ctrl+F shortcut
  /// in `main.dart`. When the Library tab is already active the field is
  /// focused without waiting for a frame; only a tab switch has to wait for
  /// the frame that shows the library.
  void focusLibrarySearch() {
    if (_tabIndex == _libraryTab) {
      _libraryKey.currentState?.focusSearch(selectAll: true);
      return;
    }
    setState(() => _tabIndex = _libraryTab);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _libraryKey.currentState?.focusSearch(selectAll: true);
    });
  }

  /// Switches the window between windowed and fullscreen.
  ///
  /// Installed app-wide by `main.dart` as F11 so it also works on pushed
  /// routes; the menu calls it directly.
  Future<void> toggleFullscreen() async {
    try {
      final fullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!fullScreen);
    } catch (error) {
      debugPrint('Vellum: fullscreen toggle failed: $error');
    }
  }

  /// Quits the application.
  ///
  /// Installed app-wide by `main.dart` as Ctrl+Q; the menu calls it directly.
  Future<void> quit() async {
    try {
      await windowManager.destroy();
    } catch (error) {
      debugPrint('Vellum: quit failed: $error');
    }
  }

  Future<void> _closeWindow() async {
    try {
      await windowManager.close();
    } catch (error) {
      debugPrint('Vellum: close failed: $error');
    }
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (context) => const AboutDialog(
        applicationName: 'Vellum',
        applicationVersion: '0.2.4',
        applicationLegalese: 'GPL-3.0',
        children: [Text('A calibre-like ebook library manager.')],
      ),
    );
  }

  void _onMenuSelected(String action, AppState state) {
    switch (action) {
      case 'preferences':
        showDialog<void>(
          context: context,
          builder: (context) => const PreferencesDialog(),
        );
      case 'import':
        unawaited(state.chooseAndImportCalibre());
      case 'hidden':
        unawaited(state.setShowHidden(!state.showHidden));
      case 'fullscreen':
        unawaited(toggleFullscreen());
      case 'about':
        _showAbout();
      case 'close':
        unawaited(_closeWindow());
      case 'quit':
        unawaited(quit());
    }
  }

  List<PopupMenuEntry<String>> _menuItems(AppState state) => [
    const PopupMenuItem<String>(
      value: 'preferences',
      child: Text('Preferences…'),
    ),
    const PopupMenuItem<String>(
      value: 'import',
      child: Text('Import Calibre Library…'),
    ),
    PopupMenuItem<String>(
      value: 'hidden',
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: state.showHidden
                ? Icon(Icons.check, size: 16, color: context.palette.accent)
                : null,
          ),
          const SizedBox(width: 8),
          const Text('Show Hidden Books'),
        ],
      ),
    ),
    const PopupMenuItem<String>(
      value: 'fullscreen',
      child: Text('Fullscreen (F11)'),
    ),
    const PopupMenuItem<String>(value: 'about', child: Text('About Vellum')),
    const PopupMenuItem<String>(value: 'close', child: Text('Close Window')),
    const PopupMenuItem<String>(value: 'quit', child: Text('Quit')),
  ];

  Widget _menuButton(AppState state, {bool expanded = false}) {
    return PopupMenuButton<String>(
      tooltip: 'Menu',
      onSelected: (action) => _onMenuSelected(action, state),
      itemBuilder: (context) => _menuItems(state),
      child: expanded
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.more_horiz,
                    size: 18,
                    color: context.palette.textDim,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Menu',
                    style: VellumType.ui(
                      12.5,
                      weight: FontWeight.w500,
                      color: context.palette.textDim,
                    ),
                  ),
                ],
              ),
            )
          : const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.more_horiz),
            ),
    );
  }

  Widget _brand() {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 26, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Vellum',
            style: VellumType.display(
              30,
              weight: FontWeight.w600,
              height: 1,
              letterSpacing: -0.6,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A reading library',
            style: VellumType.ui(11.5, height: 1.3, color: palette.textDim),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(AppState state) {
    final palette = context.palette;
    return Container(
      width: 228,
      decoration: BoxDecoration(
        color: palette.sidebar,
        border: Border(right: BorderSide(color: palette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _brand(),
          Expanded(
            child: NavigationRail(
              selectedIndex: _tabIndex,
              onDestinationSelected: _selectTab,
              extended: true,
              labelType: NavigationRailLabelType.none,
              destinations: _railDestinations,
              backgroundColor: Colors.transparent,
            ),
          ),
          Divider(height: 1, color: palette.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => const PreferencesDialog(),
                    ),
                    icon: const Icon(Icons.tune, size: 17),
                    label: const Text('Preferences'),
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: palette.textDim,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                    ),
                  ),
                ),
                _menuButton(state, expanded: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _appBar(AppState state) {
    return AppBar(
      title: Text(
        'Vellum',
        style: VellumType.display(
          23,
          weight: FontWeight.w600,
          letterSpacing: -0.3,
          color: context.palette.text,
        ),
      ),
      actions: [_menuButton(state), const SizedBox(width: 8)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 860;

    final pages = <Widget>[
      LibraryPage(key: _libraryKey),
      const ShelvesPage(),
      const StorePage(),
      const PluginsPage(),
      const StatsPage(),
    ];
    final body = IndexedStack(index: _tabIndex, children: pages);

    return Focus(
      autofocus: true,
      child: Scaffold(
        appBar: wide ? null : _appBar(state),
        body: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sidebar(state),
                  Expanded(child: body),
                ],
              )
            : body,
        bottomNavigationBar: wide ? null : _navigationBar(selected: _tabIndex),
      ),
    );
  }

  static const List<NavigationRailDestination> _railDestinations = [
    NavigationRailDestination(
      icon: Icon(Icons.auto_stories_outlined),
      selectedIcon: Icon(Icons.auto_stories),
      label: Text('Library'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.collections_bookmark_outlined),
      selectedIcon: Icon(Icons.collections_bookmark),
      label: Text('Shelves'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.download_outlined),
      selectedIcon: Icon(Icons.download),
      label: Text('Get Books'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.extension_outlined),
      selectedIcon: Icon(Icons.extension),
      label: Text('Plugins'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.insights_outlined),
      selectedIcon: Icon(Icons.insights),
      label: Text('Stats'),
    ),
  ];

  Widget _navigationBar({required int selected}) {
    return NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: _selectTab,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.auto_stories_outlined),
          selectedIcon: Icon(Icons.auto_stories),
          label: 'Library',
        ),
        NavigationDestination(
          icon: Icon(Icons.collections_bookmark_outlined),
          selectedIcon: Icon(Icons.collections_bookmark),
          label: 'Shelves',
        ),
        NavigationDestination(
          icon: Icon(Icons.download_outlined),
          selectedIcon: Icon(Icons.download),
          label: 'Get Books',
        ),
        NavigationDestination(
          icon: Icon(Icons.extension_outlined),
          selectedIcon: Icon(Icons.extension),
          label: 'Plugins',
        ),
        NavigationDestination(
          icon: Icon(Icons.insights_outlined),
          selectedIcon: Icon(Icons.insights),
          label: 'Stats',
        ),
      ],
    );
  }
}

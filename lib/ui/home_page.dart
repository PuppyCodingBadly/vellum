/// Root application shell: tab navigation, library search and main menu.
///
/// Ports `vellum/ui/window.py` (ViewSwitcher, SearchEntry, sort dropdown and
/// menu) to Material 3.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../core/sorting.dart';
import 'library_page.dart';
import 'plugins_page.dart';
import 'preferences_dialog.dart';
import 'shelves_page.dart';
import 'stats_page.dart';
import 'store_page.dart';

/// Application home: five tabs plus the shared toolbar.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _libraryTab = 0;

  int _tabIndex = _libraryTab;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;

  static const List<Widget> _pages = <Widget>[
    LibraryPage(),
    ShelvesPage(),
    StorePage(),
    PluginsPage(),
    StatsPage(),
  ];

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    if (index == _tabIndex) return;
    setState(() => _tabIndex = index);
  }

  void _focusLibrarySearch() {
    if (_tabIndex != _libraryTab) {
      setState(() => _tabIndex = _libraryTab);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
    });
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(AppState.of(context).setSearchQuery(_searchController.text));
    });
  }

  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    unawaited(AppState.of(context).setSearchQuery(value));
  }

  Future<void> _toggleFullscreen() async {
    try {
      final fullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!fullScreen);
    } catch (error) {
      debugPrint('Vellum: fullscreen toggle failed: $error');
    }
  }

  Future<void> _quit() async {
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
        applicationVersion: '0.2.0',
        applicationLegalese: 'GPL-3.0',
        children: [
          Text('A calibre-like ebook library manager.'),
        ],
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
        unawaited(_toggleFullscreen());
      case 'about':
        _showAbout();
      case 'close':
        unawaited(_closeWindow());
      case 'quit':
        unawaited(_quit());
    }
  }

  Widget _searchField() {
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: _submitSearch,
        decoration: InputDecoration(
          hintText: 'Search library…',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(AppState state) {
    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          const Text('Vellum'),
          if (_tabIndex == _libraryTab) ...[
            const SizedBox(width: 24),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _searchField(),
                ),
              ),
            ),
          ],
        ],
      ),
      actions: [
        Tooltip(
          message: 'Sort library',
          child: DropdownButton<String>(
            value: state.sortKey,
            underline: const SizedBox.shrink(),
            onChanged: (key) {
              if (key != null) unawaited(state.setSortKey(key));
            },
            items: [
              for (final (key, label) in SORT_OPTIONS)
                DropdownMenuItem<String>(value: key, child: Text(label)),
            ],
          ),
        ),
        PopupMenuButton<String>(
          onSelected: (action) => _onMenuSelected(action, state),
          itemBuilder: (context) => [
            const PopupMenuItem<String>(
              value: 'preferences',
              child: Text('Preferences…'),
            ),
            const PopupMenuItem<String>(
              value: 'import',
              child: Text('Import Calibre Library…'),
            ),
            CheckedPopupMenuItem<String>(
              value: 'hidden',
              checked: state.showHidden,
              child: const Text('Show Hidden Books'),
            ),
            const PopupMenuItem<String>(
              value: 'fullscreen',
              child: Text('Fullscreen (F11)'),
            ),
            const PopupMenuItem<String>(
              value: 'about',
              child: Text('About Vellum'),
            ),
            const PopupMenuItem<String>(
              value: 'close',
              child: Text('Close Window'),
            ),
            const PopupMenuItem<String>(
              value: 'quit',
              child: Text('Quit'),
            ),
          ],
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final body = IndexedStack(index: _tabIndex, children: _pages);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusLibrarySearch,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_toggleFullscreen()),
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () =>
            unawaited(_quit()),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: _appBar(state),
          body: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NavigationRail(
                      selectedIndex: _tabIndex,
                      onDestinationSelected: _selectTab,
                      labelType: NavigationRailLabelType.all,
                      destinations: _railDestinations,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                )
              : body,
          bottomNavigationBar:
              wide ? null : _navigationBar(selected: _tabIndex),
        ),
      ),
    );
  }

  static const List<NavigationRailDestination> _railDestinations = [
    NavigationRailDestination(
      icon: Icon(Icons.grid_view),
      label: Text('Library'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.collections_bookmark),
      label: Text('Shelves'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.download),
      selectedIcon: Icon(Icons.folder),
      label: Text('Get Books'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.extension),
      label: Text('Plugins'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.bar_chart),
      label: Text('Stats'),
    ),
  ];

  Widget _navigationBar({required int selected}) {
    return NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: _selectTab,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.grid_view),
          label: 'Library',
        ),
        NavigationDestination(
          icon: Icon(Icons.collections_bookmark),
          label: 'Shelves',
        ),
        NavigationDestination(
          icon: Icon(Icons.download),
          selectedIcon: Icon(Icons.folder),
          label: 'Get Books',
        ),
        NavigationDestination(
          icon: Icon(Icons.extension),
          label: 'Plugins',
        ),
        NavigationDestination(
          icon: Icon(Icons.bar_chart),
          label: 'Stats',
        ),
      ],
    );
  }
}

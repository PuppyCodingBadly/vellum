import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../import/importer.dart';
import '../plugins/plugin_controller.dart' show PluginInfo;
import '../store/store_download.dart';
import 'theme.dart';

/// Chooses, streams and publishes a store download.
typedef StoreDownload =
    Future<File> Function({
      required String url,
      required String title,
      required String formats,
      required String directory,
    });

/// "Get Books" tab: searches loaded calibre store plugins and downloads the
/// selected result into the current library.
class StorePage extends StatefulWidget {
  const StorePage({super.key, this.download = downloadBook});

  /// Download implementation; tests replace it so they never touch the
  /// network or the real data directory.
  final StoreDownload download;

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  final TextEditingController _query = TextEditingController();

  bool _searching = false;
  String? _selectedStore;
  List<Map<String, Object?>>? _results;
  String? _resultsStore;
  String? _searchError;

  /// Result keys with a download in flight.  A search does not clear it: the
  /// same row can come back while its download still runs.
  final Set<String> _downloading = {};

  /// Stable identity for a search result, so the same store row keeps its
  /// in-flight marker across searches; maps are recreated by every search.
  static String _resultKey(String storeName, Map<String, Object?> result) {
    final fields = [
      'store=$storeName',
      for (final entry in result.entries) '${entry.key}=${entry.value}',
    ]..sort();
    return fields.join('\u0000');
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _effectiveStore(List<PluginInfo> stores) {
    final selected = _selectedStore;
    if (selected != null && stores.any((s) => s.name == selected)) {
      return selected;
    }
    return stores.first.name;
  }

  Future<void> _search(AppState appState) async {
    if (_searching) return;
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final stores = appState.plugins.storePlugins();
    if (stores.isEmpty) return;
    final storeName = _effectiveStore(stores);
    setState(() => _searching = true);
    List<Map<String, Object?>> results;
    String? error;
    try {
      results = await appState.plugins.storeSearch(storeName, query);
    } catch (e) {
      // A failing store must not masquerade as "No results".
      results = const [];
      error = e.toString();
    }
    if (mounted) {
      setState(() {
        _searching = false;
        _results = results;
        _resultsStore = storeName;
        _searchError = error;
      });
    } else {
      _searching = false;
    }
  }

  Future<void> _download(Map<String, Object?> result, String storeName) async {
    final key = _resultKey(storeName, result);
    if (_downloading.contains(key)) return;
    final appState = AppState.of(context);
    // Only the directory is remembered across the awaits: the Library itself
    // is resolved again when the import writes, and is never touched after a
    // library switch closed it.
    final startedIn = appState.libraryDir;
    setState(() => _downloading.add(key));
    try {
      Map<String, Object?>? fetched;
      try {
        fetched = await appState.plugins.storeFetchDownload(storeName, result);
      } catch (_) {
        fetched = null;
      }
      if (fetched == null) {
        appState.showToast('Could not resolve download link');
        return;
      }
      final url = (fetched['download_url'] ?? '').toString().trim();
      if (url.isEmpty) {
        appState.showToast('Could not resolve download link');
        return;
      }

      final rawTitle = (fetched['title'] ?? result['title'] ?? '')
          .toString()
          .trim();
      final title = rawTitle.isEmpty ? 'book' : rawTitle;
      final formats = (fetched['formats'] ?? result['formats'] ?? 'epub')
          .toString();

      final File file;
      try {
        file = await widget.download(
          url: url,
          title: title,
          formats: formats,
          directory: p.join(appState.dataDir, 'downloads'),
        );
      } catch (error) {
        appState.showToast('Download failed: $error');
        return;
      }

      if (appState.libraryDir != startedIn) {
        appState.showToast(
          'Library changed during download; $title was not added',
        );
        return;
      }

      final List<int> ids;
      try {
        ids = await importPath(appState.library, file.path);
      } catch (error) {
        appState.showToast('Import failed: $error');
        return;
      }

      if (ids.isEmpty) {
        appState.showToast(
          'Downloaded $title but could not add it to the library',
        );
        return;
      }
      await appState.refresh();
      appState.showToast('Added $title to library');
    } finally {
      if (mounted) setState(() => _downloading.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final palette = context.palette;
        final stores = appState.plugins.storePlugins();
        if (stores.isEmpty) {
          return _StatusPage(
            icon: Icons.download_outlined,
            title: 'No store plugins',
            description: 'Add a calibre store plugin zip from the Plugins page',
          );
        }
        final selected = _effectiveStore(stores);
        return ColoredBox(
          color: palette.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(palette),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  VellumSpace.xl,
                  0,
                  VellumSpace.xl,
                  VellumSpace.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _query,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(appState),
                        decoration: const InputDecoration(
                          hintText: 'Search stores…',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                      ),
                    ),
                    if (stores.length > 1) ...[
                      const SizedBox(width: VellumSpace.xs),
                      DropdownButton<String>(
                        value: selected,
                        borderRadius: VellumRadius.largeAll,
                        dropdownColor: palette.surface,
                        style: VellumType.ui(12.5, color: palette.textDim),
                        items: [
                          for (final store in stores)
                            DropdownMenuItem<String>(
                              value: store.name,
                              child: Text(store.name),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _selectedStore = value);
                          }
                        },
                      ),
                    ],
                    const SizedBox(width: VellumSpace.xs),
                    FilledButton(
                      onPressed: _searching ? null : () => _search(appState),
                      child: const Text('Search'),
                    ),
                    const SizedBox(width: VellumSpace.sm),
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: _searching
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : null,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    VellumSpace.xl,
                    0,
                    VellumSpace.xl,
                    VellumSpace.xl,
                  ),
                  child: _buildResults(_resultsStore ?? selected),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(VellumPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VellumSpace.xl,
        VellumSpace.lg,
        VellumSpace.xl,
        VellumSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Get Books',
            style: VellumType.display(
              30,
              weight: FontWeight.w600,
              height: 1.1,
              letterSpacing: -0.5,
              color: palette.text,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Search the stores you have installed for a book to add.',
            style: VellumType.ui(12.5, color: palette.textDim),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(String storeName) {
    final error = _searchError;
    if (error != null) {
      return _StatusPage(
        icon: Icons.error_outline,
        title: 'Search failed',
        description: error,
      );
    }
    final results = _results;
    if (results == null) {
      return const _StatusPage(
        icon: Icons.search,
        title: 'Search for books',
        description:
            'Enter a query above to find books available for download.',
      );
    }
    if (results.isEmpty) {
      return const _StatusPage(
        icon: Icons.search,
        title: 'No results',
        description: 'Try a different query or store.',
      );
    }
    final palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: results.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: palette.line),
        itemBuilder: (context, index) => _buildRow(results[index], storeName),
      ),
    );
  }

  Widget _buildRow(Map<String, Object?> result, String storeName) {
    final palette = context.palette;
    final title = (result['title'] ?? '').toString().trim();
    final author = (result['author'] ?? '').toString().trim();
    final formats = (result['formats'] ?? '').toString().trim();
    final resultStore = (result['store_name'] ?? '').toString().trim();
    final chips = [
      for (final format in formats.split(','))
        if (format.trim().isNotEmpty) format.trim(),
    ];
    final downloading = _downloading.contains(_resultKey(storeName, result));
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VellumSpace.md,
        vertical: 10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? 'Untitled' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VellumType.ui(
                    13.5,
                    weight: FontWeight.w600,
                    height: 1.35,
                    color: palette.text,
                  ),
                ),
                if (author.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VellumType.ui(12, color: palette.textDim),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final chip in chips)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: palette.surfaceHigh,
                          borderRadius: VellumRadius.smallAll,
                          border: Border.all(color: palette.line),
                        ),
                        child: Text(
                          chip,
                          style: VellumType.ui(
                            10.5,
                            weight: FontWeight.w500,
                            color: palette.textDim,
                          ),
                        ),
                      ),
                    Text(
                      resultStore.isEmpty ? storeName : resultStore,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VellumType.ui(11, color: palette.textDim),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: VellumSpace.md),
          SizedBox(
            width: 106,
            child: Align(
              alignment: Alignment.centerRight,
              child: downloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : OutlinedButton(
                      onPressed: () => _download(result, storeName),
                      child: const Text('Download'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered icon/title/description page used for store states.
class _StatusPage extends StatelessWidget {
  const _StatusPage({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VellumSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: palette.surfaceHigh,
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.line),
                ),
                child: Icon(icon, size: 23, color: palette.textDim),
              ),
              const SizedBox(height: VellumSpace.md),
              Text(
                title,
                style: VellumType.display(
                  22,
                  weight: FontWeight.w600,
                  height: 1.2,
                  color: palette.text,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: VellumSpace.xs),
              Text(
                description,
                style: VellumType.ui(13, height: 1.55, color: palette.textDim),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

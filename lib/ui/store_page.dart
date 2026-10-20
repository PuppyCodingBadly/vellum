import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../import/importer.dart';
import '../plugins/plugin_controller.dart' show PluginInfo;
import '../store/store_download.dart';

/// "Get Books" tab: searches loaded calibre store plugins and downloads the
/// selected result into the current library.
class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  final TextEditingController _query = TextEditingController();

  bool _searching = false;
  String? _selectedStore;
  List<Map<String, Object?>>? _results;
  String? _resultsStore;
  final Set<int> _downloading = {};

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
    try {
      results = await appState.plugins.storeSearch(storeName, query);
    } catch (_) {
      results = const [];
    }
    if (mounted) {
      setState(() {
        _searching = false;
        _downloading.clear();
        _results = results;
        _resultsStore = storeName;
      });
    } else {
      _searching = false;
    }
  }

  Future<void> _download(int index, String storeName) async {
    final results = _results;
    if (results == null || index >= results.length) return;
    if (_downloading.contains(index)) return;
    final result = results[index];
    final appState = AppState.of(context);
    // Resolve the library now: the user may switch libraries mid-download.
    final library = appState.library;
    setState(() => _downloading.add(index));
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
      final url = (fetched['download_url'] ?? '').toString();
      if (url.isEmpty) {
        appState.showToast('Could not resolve download link');
        return;
      }

      final rawTitle = (fetched['title'] ?? result['title'] ?? '')
          .toString()
          .trim();
      final title = rawTitle.isEmpty ? 'book' : rawTitle;
      final formats =
          (fetched['formats'] ?? result['formats'] ?? 'epub').toString();
      final downloadsDir = p.join(appState.dataDir, 'downloads');

      String path;
      try {
        await Directory(downloadsDir).create(recursive: true);
        final fileName = sanitizeDownloadFileName(
          title,
          formats,
          exists: (candidate) =>
              File(p.join(downloadsDir, candidate)).existsSync(),
        );
        path = p.join(downloadsDir, fileName);
        await downloadToFile(url, path);
      } catch (e) {
        appState.showToast('Download failed: $e');
        return;
      }

      List<int> ids;
      try {
        ids = await importPath(library, path);
      } catch (e) {
        appState.showToast('Import failed: $e');
        return;
      }

      if (ids.isEmpty) {
        appState.showToast('Downloaded $title');
      } else if (!identical(appState.library, library)) {
        appState.showToast('Added $title to the previous library');
      } else {
        await appState.refresh();
        appState.showToast('Added $title to library');
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final stores = appState.plugins.storePlugins();
        if (stores.isEmpty) {
          return const _StatusPage(
            icon: Icons.download,
            title: 'No store plugins',
            description:
                'Add a calibre store plugin zip from the Plugins page',
          );
        }
        final selected = _effectiveStore(stores);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(appState),
                      decoration: const InputDecoration(
                        hintText: 'Search stores…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  if (stores.length > 1) ...[
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: selected,
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedStore = value);
                        }
                      },
                      items: [
                        for (final store in stores)
                          DropdownMenuItem<String>(
                            value: store.name,
                            child: Text(store.name),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _searching ? null : () => _search(appState),
                    child: const Text('Search'),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: _searching
                        ? const CircularProgressIndicator(strokeWidth: 2)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(child: _buildResults(_resultsStore ?? selected)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildResults(String storeName) {
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: results.length,
      itemBuilder: (context, index) =>
          _buildRow(index, results[index], storeName),
    );
  }

  Widget _buildRow(
    int index,
    Map<String, Object?> result,
    String storeName,
  ) {
    final theme = Theme.of(context);
    final title = (result['title'] ?? '').toString().trim();
    final author = (result['author'] ?? '').toString().trim();
    final formats = (result['formats'] ?? '').toString().trim();
    final resultStore = (result['store_name'] ?? '').toString().trim();
    final chips = [
      for (final format in formats.split(','))
        if (format.trim().isNotEmpty) format.trim(),
    ];
    final downloading = _downloading.contains(index);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          title.isEmpty ? 'Untitled' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (author.isNotEmpty)
              Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  for (final chip in chips) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        chip,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      resultStore.isEmpty ? storeName : resultStore,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        trailing: SizedBox(
          width: 104,
          child: Align(
            alignment: Alignment.centerRight,
            child: downloading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinedButton(
                    onPressed: () => _download(index, storeName),
                    child: const Text('Download'),
                  ),
          ),
        ),
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
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

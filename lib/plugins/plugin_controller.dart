/// App-facing facade over the plugin sidecar.
///
/// Owns a [SidecarClient] bound to one plugin directory.  Starts the
/// sidecar and loads every plugin zip in the directory on [start].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sidecar_client.dart';

export 'sidecar_client.dart'
    show PluginInfo, PluginLoadResult, LoadedPlugins, SidecarException;

class PluginController extends ChangeNotifier {
  PluginController({
    required this.pluginDir,
    SidecarClient? client,
  }) : client = client ?? SidecarClient();

  final String pluginDir;
  final SidecarClient client;

  bool _started = false;
  bool _disposed = false;
  Future<void>? _starting;
  List<PluginInfo> _metadata = const [];
  List<PluginInfo> _stores = const [];

  /// Start the sidecar (if not already running) and load all plugins.
  ///
  /// Concurrent callers share one in-flight start.  Idempotent once loaded.
  Future<void> start() {
    if (_started) return Future<void>.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    try {
      await _loadAll();
    } finally {
      _starting = null;
    }
  }

  Future<void> _loadAll() async {
    final loaded = await client.loadAll(pluginDir);
    _metadata = loaded.metadata;
    _stores = loaded.stores;
    _started = true;
    debugPrint('Vellum: loaded ${_metadata.length} metadata plugins and '
        '${_stores.length} store plugins');
    _notify();
  }

  Future<void> _ensureStarted() async {
    if (!_started) await start();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Install a plugin zip: the sidecar copies it into [pluginDir] and loads
  /// it.  Returns the load result (`kind` is `'metadata'` or `'store'`).
  Future<PluginLoadResult> addPlugin(String zipPath) async {
    await _ensureStarted();
    final result = await client.load(pluginDir, zipPath);
    await _refresh();
    return result;
  }

  /// Remove a metadata plugin by name (metadata plugins only).
  Future<bool> removePlugin(String name) async {
    await _ensureStarted();
    final removed = await client.unload(pluginDir, name);
    await _refresh();
    return removed;
  }

  Future<void> _refresh() async {
    final loaded = await client.loaded(pluginDir);
    _metadata = loaded.metadata;
    _stores = loaded.stores;
    _notify();
  }

  /// Currently loaded metadata plugins.
  List<PluginInfo> metadataPlugins() => List.unmodifiable(_metadata);

  /// Currently loaded store plugins.
  List<PluginInfo> storePlugins() => List.unmodifiable(_stores);

  Future<List<Map<String, Object?>>> metadataSearch({
    String title = '',
    List<String>? authors,
    String isbn = '',
    double timeout = 15.0,
  }) async {
    await _ensureStarted();
    return client.metadataSearch(
        title: title, authors: authors, isbn: isbn, timeout: timeout);
  }

  Future<Uint8List?> downloadCover(Map<String, Object?> meta,
      {double timeout = 15.0}) async {
    await _ensureStarted();
    return client.downloadCover(meta, timeout: timeout);
  }

  Future<List<Map<String, Object?>>> storeSearch(
    String store,
    String query, {
    int maxResults = 10,
    double timeout = 60.0,
  }) async {
    await _ensureStarted();
    return client.storeSearch(store, query,
        maxResults: maxResults, timeout: timeout);
  }

  Future<Map<String, Object?>?> storeFetchDownload(
    String store,
    Map<String, Object?> result, {
    double timeout = 60.0,
  }) async {
    await _ensureStarted();
    return client.storeFetchDownload(store, result, timeout: timeout);
  }

  /// Kill the sidecar process.
  @override
  void dispose() {
    _disposed = true;
    unawaited(client.dispose());
    super.dispose();
  }
}

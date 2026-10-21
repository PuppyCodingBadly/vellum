/// Dart client for the Vellum plugin sidecar.
///
/// Spawns `python3 <repoRoot>/sidecar/main.py` and speaks the
/// line-delimited JSON protocol: each request
/// `{"id": N, "method": m, "params": {...}}` written to stdin is answered
/// on stdout with `{"id": N, "result": ...}` or `{"id": N, "error": ...}`.
///
/// Concurrent in-flight requests are matched by id.  If the process dies
/// while requests are pending, it is restarted once and the requests are
/// retried exactly once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Error reported by the sidecar (the `error` key of a response) or by a
/// process-level failure (exit while requests are in flight).
class SidecarException implements Exception {
  SidecarException(this.message);
  final String message;

  @override
  String toString() => 'SidecarException: $message';
}

/// One loaded plugin entry as reported by `load_all` / `loaded`.
class PluginInfo {
  const PluginInfo({
    required this.name,
    this.version = '',
    this.description = '',
  });

  factory PluginInfo.fromJson(Map<String, Object?> json) => PluginInfo(
        name: (json['name'] ?? '').toString(),
        version: (json['version'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
      );

  final String name;
  final String version;
  final String description;

  @override
  String toString() => 'PluginInfo($name, $version)';
}

/// Result of `load_all` / `loaded`.
class LoadedPlugins {
  const LoadedPlugins({this.metadata = const [], this.stores = const []});

  factory LoadedPlugins.fromJson(Map<String, Object?> json) => LoadedPlugins(
        metadata: [
          for (final e in (json['metadata'] as List? ?? const []))
            PluginInfo.fromJson(Map<String, Object?>.from(e as Map)),
        ],
        stores: [
          for (final e in (json['stores'] as List? ?? const []))
            PluginInfo.fromJson(Map<String, Object?>.from(e as Map)),
        ],
      );

  final List<PluginInfo> metadata;
  final List<PluginInfo> stores;
}

/// Result of loading a single plugin zip (`load`).
typedef PluginLoadResult = ({
  String kind, // 'metadata' | 'store'
  String name,
  String version,
  String description,
});

class _Pending {
  _Pending({
    required this.method,
    required this.params,
    required this.timeout,
    required this.completer,
  });

  final String method;
  final Map<String, Object?> params;
  final Duration timeout;
  final Completer<Object?> completer;
  Timer? timer;
  bool retried = false;
}

/// Client for the Python plugin sidecar process.
class SidecarClient {
  /// [sidecarPath] overrides the path to `sidecar/main.py`; when omitted it
  /// is discovered by walking up from [Directory.current] and then from the
  /// executable's directory tree.  [pythonExecutable] overrides the Python
  /// interpreter.  [command] fully overrides the spawned command (used by
  /// tests).  [timeout] is the default per-request timeout.
  SidecarClient({
    String? sidecarPath,
    this.pythonExecutable = 'python3',
    List<String>? command,
    Duration timeout = const Duration(seconds: 90),
  })  : sidecarPath = sidecarPath ?? findSidecarMain(),
        _command = command,
        defaultTimeout = timeout;

  final String? sidecarPath;
  final String pythonExecutable;
  final Duration defaultTimeout;
  final List<String>? _command;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  int _nextId = 1;
  final Map<int, _Pending> _pending = {};
  bool _disposed = false;
  Future<Process>? _starting;

  /// Captured stderr lines from the sidecar process.
  final List<String> stderrLog = [];

  /// Locate `sidecar/main.py`: walk up from the current working directory,
  /// then from the executable's directory tree.  Returns null if not found.
  static String? findSidecarMain() {
    String? probe(Directory start) {
      var dir = start.absolute;
      while (true) {
        final candidate =
            '${dir.path}${Platform.pathSeparator}sidecar${Platform.pathSeparator}main.py';
        if (File(candidate).existsSync()) return candidate;
        final parent = dir.parent;
        if (parent.path == dir.path) return null;
        dir = parent;
      }
    }

    return probe(Directory.current) ??
        probe(Directory(File(Platform.resolvedExecutable).parent.path));
  }

  List<String> _effectiveCommand() {
    final cmd = _command;
    if (cmd != null) return cmd;
    final path = sidecarPath;
    if (path == null) {
      throw SidecarException('could not locate sidecar/main.py');
    }
    return [pythonExecutable, path];
  }

  Future<Process> _ensureProcess() {
    final running = _process;
    if (running != null) return Future.value(running);
    return _starting ??= Process.start(
      _effectiveCommand().first,
      _effectiveCommand().sublist(1),
    ).then((proc) {
      if (_disposed) {
        // dispose() ran while the spawn was in flight: kill the late
        // process instead of leaking it, and fail the waiter.
        proc.kill();
        throw SidecarException('sidecar disposed');
      }
      _process = proc;
      _starting = null;
      _stdoutSub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onStdoutLine, onError: (_) {});
      _stderrSub = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stderrLog.add(line), onError: (_) {});
      proc.exitCode.then((_) => _onProcessExit(proc));
      return proc;
    }).whenComplete(() => _starting = null);
  }

  void _onStdoutLine(String line) {
    if (line.trim().isEmpty) return;
    Map<String, Object?> resp;
    try {
      resp = Map<String, Object?>.from(jsonDecode(line) as Map);
    } catch (_) {
      return; // not a protocol line; ignore
    }
    final id = resp['id'];
    if (id is! int) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    if (resp.containsKey('error')) {
      pending.completer.completeError(SidecarException('${resp['error']}'));
    } else {
      pending.completer.complete(resp['result']);
    }
  }

  void _onProcessExit(Process proc) {
    if (proc != _process) return;
    _process = null;
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (_disposed) {
      for (final p in _pending.values) {
        p.timer?.cancel();
        p.completer.completeError(SidecarException('sidecar disposed'));
      }
      _pending.clear();
      return;
    }
    // Died with requests in flight: restart once and retry each once.
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      p.timer?.cancel();
      if (p.retried) {
        p.completer.completeError(
            SidecarException('sidecar process died mid-request'));
        continue;
      }
      p.retried = true;
      _retry(p);
    }
  }

  Future<void> _retry(_Pending p) async {
    try {
      await _ensureProcess();
      if (_disposed) throw SidecarException('sidecar disposed');
      _send(p.method, p.params, p.timeout, p);
    } catch (e) {
      p.completer.completeError(
          e is SidecarException ? e : SidecarException('$e'));
    }
  }

  int _send(String method, Map<String, Object?> params, Duration timeout,
      [_Pending? existing]) {
    final proc = _process;
    if (proc == null) {
      throw SidecarException('sidecar process not running');
    }
    final pending =
        existing ?? _Pending(method: method, params: params, timeout: timeout, completer: Completer<Object?>());
    final id = _nextId++;
    _pending[id] = pending;
    pending.timer = Timer(timeout, () {
      if (_pending.remove(id) != null) {
        pending.completer.completeError(
            TimeoutException('sidecar request $method timed out', timeout));
      }
    });
    try {
      proc.stdin
          .writeln(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (e) {
      // Write failed (process died between _ensureProcess and _send):
      // roll back the pending entry and its timer so nothing orphaned
      // completes the completer later.
      _pending.remove(id);
      pending.timer?.cancel();
      rethrow;
    }
    return id;
  }

  /// Raw protocol call; returns the decoded `result` value.
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (_disposed) throw SidecarException('sidecar client disposed');
    await _ensureProcess();
    if (_disposed) throw SidecarException('sidecar client disposed');
    final pending = _Pending(
      method: method,
      params: params,
      timeout: timeout ?? defaultTimeout,
      completer: Completer<Object?>(),
    );
    try {
      _send(method, params, pending.timeout, pending);
    } catch (e) {
      throw e is SidecarException ? e : SidecarException('$e');
    }
    return pending.completer.future;
  }

  // -- sidecar methods ------------------------------------------------------

  Future<String> ping() async => (await call('ping', const {})) as String;

  Future<LoadedPlugins> loadAll(String pluginDir) async =>
      LoadedPlugins.fromJson(Map<String, Object?>.from(
          await call('load_all', {'plugin_dir': pluginDir}) as Map));

  Future<PluginLoadResult> load(String pluginDir, String zipPath) async {
    final r = Map<String, Object?>.from(
        await call('load', {'plugin_dir': pluginDir, 'zip_path': zipPath})
            as Map);
    return (
      kind: (r['kind'] ?? '').toString(),
      name: (r['name'] ?? '').toString(),
      version: (r['version'] ?? '').toString(),
      description: (r['description'] ?? '').toString(),
    );
  }

  Future<bool> unload(String pluginDir, String name) async =>
      await call('unload', {'plugin_dir': pluginDir, 'name': name}) as bool;

  Future<LoadedPlugins> loaded(String pluginDir) async =>
      LoadedPlugins.fromJson(Map<String, Object?>.from(
          await call('loaded', {'plugin_dir': pluginDir}) as Map));

  Future<List<Map<String, Object?>>> metadataSearch({
    String title = '',
    List<String>? authors,
    String isbn = '',
    double timeout = 15.0,
  }) async {
    final r = await call('metadata_search', {
      'title': title,
      'authors': authors,
      'isbn': isbn,
      'timeout': timeout,
    });
    return [
      for (final e in (r as List? ?? const []))
        Map<String, Object?>.from(e as Map),
    ];
  }

  /// Returns the decoded cover bytes, or null when no cover was found.
  Future<Uint8List?> downloadCover(Map<String, Object?> meta,
      {double timeout = 15.0}) async {
    final r = Map<String, Object?>.from(await call(
        'download_cover', {'meta': meta, 'timeout': timeout}) as Map);
    final data = r['data'];
    if (data is! String || data.isEmpty) return null;
    return base64.decode(data);
  }

  Future<List<Map<String, Object?>>> storeSearch(
    String store,
    String query, {
    int maxResults = 10,
    double timeout = 60.0,
  }) async {
    final r = await call('store_search', {
      'store': store,
      'query': query,
      'max_results': maxResults,
      'timeout': timeout,
    });
    return [
      for (final e in (r as List? ?? const []))
        Map<String, Object?>.from(e as Map),
    ];
  }

  Future<Map<String, Object?>?> storeFetchDownload(
    String store,
    Map<String, Object?> result, {
    double timeout = 60.0,
  }) async {
    final r = await call('store_fetch_download', {
      'store': store,
      'result': result,
      'timeout': timeout,
    });
    return r == null ? null : Map<String, Object?>.from(r as Map);
  }

  /// Kill the sidecar process and fail any in-flight requests.
  Future<void> dispose() async {
    _disposed = true;
    for (final p in _pending.values) {
      p.timer?.cancel();
      p.completer.completeError(SidecarException('sidecar disposed'));
    }
    _pending.clear();
    final proc = _process;
    _process = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    proc?.kill();
  }
}

/// Dart client for the Vellum plugin sidecar.
///
/// Spawns `python3 <executable dir>/sidecar/main.py` and speaks the
/// line-delimited JSON protocol: each request
/// `{"id": N, "method": m, "params": {...}}` written to stdin is answered
/// on stdout with `{"id": N, "result": ...}` or `{"id": N, "error": ...}`.
///
/// Concurrent in-flight requests are matched by id.  If the process dies
/// while requests are pending, it is restarted once and the requests are
/// retried exactly once.  A sidecar that stops answering is killed after a few
/// consecutive request timeouts, and a sidecar that keeps dying is left down
/// (see [SidecarClient.isHealthy]) instead of being respawned forever.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
  /// Restarts allowed inside [_restartWindow] before the client stops
  /// respawning a crash-looping sidecar.
  static const int _maxRestarts = 3;
  static const Duration _restartWindow = Duration(minutes: 1);

  /// Consecutive request timeouts that mean the sidecar is wedged rather than
  /// slow: still alive, but it answers nothing, so every later request times
  /// out too.
  static const int _timeoutLimit = 3;

  /// Stderr lines kept from the current process.
  static const int _stderrLimit = 200;

  static const String _budgetMessage =
      'sidecar crashed repeatedly and was not restarted; call start() to retry';

  /// [sidecarPath] overrides the path to `sidecar/main.py`; when omitted it is
  /// the bundled copy next to the executable (see [findSidecarMain]).
  /// [pythonExecutable] overrides the Python interpreter.  [command] fully
  /// overrides the spawned command (used by tests).  [timeout] is the default
  /// per-request timeout.
  SidecarClient({
    String? sidecarPath,
    this.pythonExecutable = 'python3',
    List<String>? command,
    Duration timeout = const Duration(seconds: 90),
  }) : sidecarPath = sidecarPath ?? findSidecarMain(),
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
  Future<void>? _restartFuture;

  /// When each restart was spawned; the initial spawn is not a restart.
  final List<DateTime> _restarts = [];
  bool _spawned = false;
  int _consecutiveTimeouts = 0;
  bool _unhealthy = false;

  /// Runs after the sidecar process dies, before in-flight requests are
  /// retried. The plugin controller uses it to restore the plugin registry in
  /// the fresh process; null means no state to restore.
  Future<void> Function()? onRestart;

  final List<String> _stderrLines = [];
  late final List<String> _stderrLog = UnmodifiableListView<String>(
    _stderrLines,
  );

  /// The last [_stderrLimit] stderr lines of the current sidecar process,
  /// oldest first.
  ///
  /// A read-only view of a bounded buffer: the oldest line is dropped when the
  /// buffer is full, and the buffer is cleared when a new process starts, so
  /// it always describes the process that is running now.
  List<String> get stderrLog => _stderrLog;

  /// Whether the client may still use the sidecar. False after [dispose], and
  /// after the restart budget is spent, which means the process is
  /// crash-looping and only an explicit [start] may try again.
  bool get isHealthy => !_disposed && !_unhealthy;

  /// Locate the bundled `sidecar/main.py`.
  ///
  /// Only the executable's own directory is trusted: the working directory is
  /// wherever the user launched us — a document folder or `/tmp` — so it must
  /// never decide which Python file gets executed. Debug builds additionally
  /// accept the working directory, which is how `flutter run` from a checkout
  /// finds the repository's sidecar.
  ///
  /// [executablePath], [workingDirectory] and [allowWorkingDirectory] default
  /// to the running process, [Directory.current] and [kDebugMode]; tests pin
  /// them to check the policy without planting files next to the test runner.
  static String? findSidecarMain({
    String? executablePath,
    String? workingDirectory,
    bool? allowWorkingDirectory,
  }) {
    final executable = executablePath ?? Platform.resolvedExecutable;
    final bundled = _sidecarUnder(File(executable).parent);
    if (bundled != null) return bundled;
    if (!(allowWorkingDirectory ?? kDebugMode)) return null;
    return _sidecarUnder(Directory(workingDirectory ?? Directory.current.path));
  }

  /// `<root>/sidecar/main.py` when it is a regular file that resolves inside
  /// [root]; null otherwise.
  ///
  /// Symbolic links are resolved and the result must stay under [root], so a
  /// `sidecar` directory linked to a writable cache or temp dir is rejected
  /// rather than executed. Directories, FIFOs and other non-regular files are
  /// rejected too.
  static String? _sidecarUnder(Directory root) {
    final String rootPath;
    try {
      rootPath = root.resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
    final candidate =
        '$rootPath${Platform.pathSeparator}sidecar'
        '${Platform.pathSeparator}main.py';
    final String resolved;
    try {
      resolved = File(candidate).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
    if (!resolved.startsWith('$rootPath${Platform.pathSeparator}')) {
      return null;
    }
    return FileSystemEntity.typeSync(resolved) == FileSystemEntityType.file
        ? resolved
        : null;
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
    if (_unhealthy) return Future.error(_budgetExhausted());
    return _starting ??= _spawn().whenComplete(() => _starting = null);
  }

  /// Spawns a process, charging a restart against the budget unless this is the
  /// very first spawn. Once the budget for [_restartWindow] is spent the client
  /// goes unhealthy and refuses to spawn until [start] clears it, so a sidecar
  /// that kills the interpreter on start cannot crash-loop forever.
  Future<Process> _spawn() async {
    final command = _effectiveCommand();
    final now = DateTime.now();
    _restarts.removeWhere((at) => now.difference(at) >= _restartWindow);
    if (_spawned && _restarts.length >= _maxRestarts) {
      _unhealthy = true;
      throw _budgetExhausted();
    }
    final proc = await Process.start(command.first, command.sublist(1));
    if (_spawned) {
      _restarts.add(now);
    } else {
      _spawned = true;
    }
    if (_disposed) {
      // dispose() ran while the spawn was in flight: kill the late
      // process instead of leaking it, and fail the waiter.
      proc.kill();
      throw SidecarException('sidecar disposed');
    }
    _process = proc;
    _consecutiveTimeouts = 0;
    _stderrLines.clear();
    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdoutLine, onError: (_) {});
    _stderrSub = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_addStderrLine, onError: (_) {});
    proc.exitCode.then((_) => _onProcessExit(proc));
    return proc;
  }

  SidecarException _budgetExhausted() => SidecarException(_budgetMessage);

  /// Appends one stderr line, dropping the oldest once the buffer is full.
  void _addStderrLine(String line) {
    if (_stderrLines.length == _stderrLimit) _stderrLines.removeAt(0);
    _stderrLines.add(line);
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
    // Any protocol answer proves the process is alive and answering.
    _consecutiveTimeouts = 0;
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
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      p.timer?.cancel();
    }
    if (_disposed) {
      _failAll(pending, 'sidecar disposed');
      return;
    }
    if (_unhealthy) {
      // The restart budget is spent: stay down instead of respawning on every
      // death, and make the failure visible to the callers.
      _failAll(pending, _budgetMessage);
      return;
    }
    // Died with requests in flight: restore process state, then retry each
    // request once.
    unawaited(_restartPending(pending));
  }

  void _failAll(Iterable<_Pending> pending, String message) {
    for (final p in pending) {
      if (!p.completer.isCompleted) {
        p.completer.completeError(SidecarException(message));
      }
    }
  }

  Future<void> _restartPending(List<_Pending> pending) async {
    try {
      await _waitForRestart();
    } catch (error) {
      _failAll(pending, error is SidecarException ? error.message : '$error');
      return;
    }
    if (_disposed) {
      _failAll(pending, 'sidecar disposed');
      return;
    }
    for (final p in pending) {
      if (p.retried) {
        _failAll([p], 'sidecar process died mid-request');
        continue;
      }
      p.retried = true;
      _retry(p);
    }
  }

  /// Runs [onRestart] once per process death, sharing the in-flight run.
  Future<void> _waitForRestart() {
    final hook = onRestart;
    if (hook == null) return Future<void>.value();
    return _restartFuture ??= Future<void>.sync(
      hook,
    ).whenComplete(() => _restartFuture = null);
  }

  Future<void> _retry(_Pending p) async {
    try {
      await _ensureProcess();
      if (_disposed) throw SidecarException('sidecar disposed');
      _send(p.method, p.params, p.timeout, p);
    } catch (e) {
      p.completer.completeError(
        e is SidecarException ? e : SidecarException('$e'),
      );
    }
  }

  int _send(
    String method,
    Map<String, Object?> params,
    Duration timeout, [
    _Pending? existing,
  ]) {
    final proc = _process;
    if (proc == null) {
      throw SidecarException('sidecar process not running');
    }
    final pending =
        existing ??
        _Pending(
          method: method,
          params: params,
          timeout: timeout,
          completer: Completer<Object?>(),
        );
    final id = _nextId++;
    _pending[id] = pending;
    pending.timer = Timer(timeout, () {
      if (_pending.remove(id) != null) {
        pending.completer.completeError(
          TimeoutException('sidecar request $method timed out', timeout),
        );
        _onRequestTimeout();
      }
    });
    try {
      proc.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
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

  /// Retires a sidecar that has stopped answering.
  ///
  /// Timeouts are the only symptom of a wedged process: it stays alive and
  /// every later request times out too, so once [_timeoutLimit] consecutive
  /// requests timed out the process is killed through [_onProcessExit], which
  /// fails the requests still in flight, runs [onRestart] and respawns on
  /// demand. A process that wedges again lands in the restart budget, so this
  /// cannot become a kill loop.
  void _onRequestTimeout() {
    if (++_consecutiveTimeouts < _timeoutLimit) return;
    _consecutiveTimeouts = 0;
    final proc = _process;
    if (proc == null) return;
    _onProcessExit(proc);
    proc.kill(ProcessSignal.sigkill);
  }

  /// Starts the sidecar explicitly, clearing the unhealthy state and the
  /// restart budget.
  ///
  /// The client respawns on demand for ordinary crashes; this is the way back
  /// after [isHealthy] turned false because the sidecar kept crashing.
  Future<void> start() async {
    if (_disposed) throw SidecarException('sidecar client disposed');
    _unhealthy = false;
    _restarts.clear();
    _consecutiveTimeouts = 0;
    await _ensureProcess();
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
      LoadedPlugins.fromJson(
        Map<String, Object?>.from(
          await call('load_all', {'plugin_dir': pluginDir}) as Map,
        ),
      );

  Future<PluginLoadResult> load(String pluginDir, String zipPath) async {
    final r = Map<String, Object?>.from(
      await call('load', {'plugin_dir': pluginDir, 'zip_path': zipPath}) as Map,
    );
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
      LoadedPlugins.fromJson(
        Map<String, Object?>.from(
          await call('loaded', {'plugin_dir': pluginDir}) as Map,
        ),
      );

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
  Future<Uint8List?> downloadCover(
    Map<String, Object?> meta, {
    double timeout = 15.0,
  }) async {
    final r = Map<String, Object?>.from(
      await call('download_cover', {'meta': meta, 'timeout': timeout}) as Map,
    );
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

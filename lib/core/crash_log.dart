/// Append-only crash and startup diagnostics log.
///
/// A production SIGTRAP once exited the app with no application-side trace;
/// every uncaught error and every startup stage now lands here so a session
/// that dies natively still leaves a breadcrumb trail.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Writes timestamped, newline-delimited entries to `<dataDir>/crash.log`.
///
/// Logging is best-effort by contract: an unwritable log must never take the
/// app down or mask the original error.
class CrashLog {
  CrashLog(Directory dataDir) : file = File(p.join(dataDir.path, 'crash.log'));

  /// File receiving the entries (`~/.local/share/vellum/crash.log`).
  final File file;

  /// Longest stack trace kept per entry, to bound disk growth on error storms.
  static const int maxTraceLength = 64 * 1024;

  /// Appends a free-form [message]; returns `false` when the write failed.
  bool write(String message) {
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Records a startup/lifecycle marker (for example `startup`, `run-app`).
  bool stage(String name) => write('STAGE $name');

  /// Records [error] and its [stackTrace] attributable to [stage].
  bool recordError(String stage, Object error, StackTrace stackTrace) {
    var trace = stackTrace.toString();
    if (trace.length > maxTraceLength) {
      trace = '${trace.substring(0, maxTraceLength)}\n… (truncated)';
    }
    return write('ERROR [$stage] $error\n$trace');
  }
}

/// Routes app-wide Flutter and platform errors into [crashLog].
///
/// Widget-build/handler exceptions flow through [FlutterError.onError] and
/// uncaught asynchronous errors through `PlatformDispatcher.onError`; both are
/// logged and swallowed so one bad callback cannot end the session.
void installCrashHandlers(CrashLog crashLog) {
  FlutterError.onError = (details) {
    crashLog.recordError(
      'flutter',
      details.exception,
      details.stack ?? StackTrace.current,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    crashLog.recordError('platform', error, stackTrace);
    return true;
  };
}

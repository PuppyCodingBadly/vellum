import '../core/db.dart';

/// Tracks reading sessions and exposes reading statistics.
///
/// [startSession] records the current UTC time; [endSession] persists the
/// session via [Library.addReadingSession]. Calling [endSession] without an
/// active session is a no-op.
class ReadingStatsTracker {
  ReadingStatsTracker(this._library, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Library _library;
  final DateTime Function() _now;

  final Map<int, DateTime> _active = <int, DateTime>{};
  int? _lastBookId;

  /// Records the start of a reading session for [bookId].
  void startSession(int bookId) {
    _active[bookId] = _now().toUtc();
    _lastBookId = bookId;
  }

  /// Ends the session for the most recently started book (or [bookId] if
  /// provided implicitly by an active session) and persists it. No-op when
  /// no session is active.
  void endSession(String endLocator) {
    final bookId = _lastBookId;
    if (bookId == null) return;
    final started = _active.remove(bookId);
    if (started == null) return;
    _lastBookId = _active.isEmpty ? null : _active.keys.last;
    final elapsed = _now().toUtc().difference(started);
    final seconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
    _library.addReadingSession(
      bookId,
      started.toIso8601String(),
      seconds,
      endLocator,
    );
  }

  /// Elapsed time of the active session for [bookId], or null when none.
  Duration? activeElapsed(int bookId) {
    final started = _active[bookId];
    if (started == null) return null;
    return _now().toUtc().difference(started);
  }

  /// Per-book statistics; delegates to [Library.statsForBook].
  Map<String, Object?> bookSummary(int bookId) =>
      _library.statsForBook(bookId);

  /// Library-wide statistics; delegates to [Library.libraryStats].
  Map<String, Object?> librarySummary() => _library.libraryStats();

  /// Most recent reading sessions across the library, newest first;
  /// delegates to [Library.recentReadingSessions].
  List<Map<String, Object?>> recentSessions(int limit) =>
      _library.recentReadingSessions(limit);
}

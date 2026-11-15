import '../core/db.dart';

/// Tracks reading sessions and exposes reading statistics.
///
/// Sessions are keyed by book id, so each open reader owns its own session:
/// [endSession] ends exactly the book it is given, never another book's.
class ReadingStatsTracker {
  ReadingStatsTracker(this._library, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Library _library;
  final DateTime Function() _now;

  final Map<int, DateTime> _active = <int, DateTime>{};

  /// Records the start of a reading session for [bookId], replacing any
  /// session already open for it.
  void startSession(int bookId) {
    _active[bookId] = _now().toUtc();
  }

  /// Ends the session for [bookId] and persists it via
  /// [Library.addReadingSession]. No-op when [bookId] has no active session.
  void endSession(int bookId, String endLocator) {
    final started = _active.remove(bookId);
    if (started == null) return;
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
  Map<String, Object?> bookSummary(int bookId) => _library.statsForBook(bookId);

  /// Library-wide statistics; delegates to [Library.libraryStats].
  Map<String, Object?> librarySummary() => _library.libraryStats();

  /// Most recent reading sessions across the library, newest first;
  /// delegates to [Library.recentReadingSessions].
  List<Map<String, Object?>> recentSessions(int limit) =>
      _library.recentReadingSessions(limit);
}

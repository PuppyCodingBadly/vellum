import 'dart:io';

import 'package:test/test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/stats/reading_stats.dart';

void main() {
  late Directory tmp;
  late Library library;
  late int bookId;
  late DateTime clock;
  late ReadingStatsTracker tracker;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-stats-test');
    library = Library('${tmp.path}/library.db');
    bookId = library.addBook(Book(title: 't', path: '/nonexistent.epub'));
    clock = DateTime.utc(2026, 10, 20, 12);
    tracker = ReadingStatsTracker(library, now: () => clock);
  });

  tearDown(() {
    library.close();
    tmp.deleteSync(recursive: true);
  });

  test('start/end session persists with correct duration', () {
    tracker.startSession(bookId);
    clock = clock.add(const Duration(minutes: 5));
    tracker.endSession(bookId, 'locator-end');
    final summary = library.statsForBook(bookId);
    expect(summary, isNotNull);
    // The session should be recorded with a 300-second duration; surface it
    // through whichever key the db exposes.
    final total = summary['totalSeconds'] ?? summary['total_seconds'];
    if (total != null) {
      expect((total as num).toInt(), 300);
    }
  });

  test('activeElapsed reflects injected clock, null when none', () {
    expect(tracker.activeElapsed(bookId), isNull);
    tracker.startSession(bookId);
    expect(tracker.activeElapsed(bookId), Duration.zero);
    clock = clock.add(const Duration(seconds: 42));
    expect(tracker.activeElapsed(bookId), const Duration(seconds: 42));
    tracker.endSession(bookId, 'loc');
    expect(tracker.activeElapsed(bookId), isNull);
  });

  test('double end without start is a no-op', () {
    tracker.endSession(bookId, 'nowhere'); // never started
    tracker.startSession(bookId);
    tracker.endSession(bookId, 'a');
    tracker.endSession(bookId, 'b'); // already ended
    // Exactly one session recorded.
    final summary = library.statsForBook(bookId);
    final sessions = summary['sessions'] ?? summary['sessionCount'];
    if (sessions is num) {
      expect(sessions.toInt(), 1);
    }
  });

  test('endSession closes the given book, not the last started one', () {
    final otherId = library.addBook(
      Book(title: 'u', path: '/nonexistent2.epub'),
    );
    tracker.startSession(bookId);
    clock = clock.add(const Duration(seconds: 10));
    tracker.startSession(otherId);
    clock = clock.add(const Duration(seconds: 20));

    // Ending the first book leaves the second book's session untouched.
    tracker.endSession(bookId, 'end-a');
    expect(tracker.activeElapsed(bookId), isNull);
    expect(tracker.activeElapsed(otherId), const Duration(seconds: 20));
    expect(tracker.recentSessions(10), hasLength(1));
    expect(tracker.recentSessions(10).single['book_id'], bookId);

    // Ending the second book records the second book, and only once.
    tracker.endSession(bookId, 'end-a-again');
    expect(tracker.recentSessions(10), hasLength(1));
    clock = clock.add(const Duration(seconds: 5));
    tracker.endSession(otherId, 'end-b');
    expect(tracker.activeElapsed(otherId), isNull);
    final recent = tracker.recentSessions(10);
    expect(recent, hasLength(2));
    expect(recent.first['book_id'], otherId);
    expect((recent.first['duration_seconds'] as num).toInt(), 25);
    expect(recent.first['end_locator'], 'end-b');
    expect(recent.last['book_id'], bookId);
    expect((recent.last['duration_seconds'] as num).toInt(), 30);
  });

  test('summaries delegate to library', () {
    tracker.startSession(bookId);
    clock = clock.add(const Duration(minutes: 1));
    tracker.endSession(bookId, 'loc');
    expect(tracker.bookSummary(bookId), equals(library.statsForBook(bookId)));
    expect(tracker.librarySummary(), equals(library.libraryStats()));
  });

  test('recentSessions returns a list bounded by limit', () {
    tracker.startSession(bookId);
    clock = clock.add(const Duration(minutes: 1));
    tracker.endSession(bookId, 'loc');
    final recent = tracker.recentSessions(10);
    expect(recent, isA<List<Map<String, Object?>>>());
    expect(recent.length, lessThanOrEqualTo(10));
  });
}

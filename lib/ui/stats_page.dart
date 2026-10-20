import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/db.dart';
import '../core/models.dart';

/// Reading statistics page: library totals, recent sessions, and per-book
/// totals sourced from the reading-session log.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  Library? _cachedLibrary;
  int _cachedSessions = -1;
  int _cachedTotalSeconds = -1;
  Map<int, _BookStatData> _cachedData = const <int, _BookStatData>{};

  @override
  Widget build(BuildContext context) {
    final appState = AppState.of(context);
    return ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final theme = Theme.of(context);
        final library = appState.library;
        final summary = library.libraryStats();
        final totalSeconds =
            (summary['totalSeconds'] as num?)?.toInt() ?? 0;
        final booksRead = (summary['booksRead'] as num?)?.toInt() ?? 0;
        final sessionCount = (summary['sessions'] as num?)?.toInt() ?? 0;
        final recent = appState.stats.recentSessions(50);
        final perBook = _perBookStats(
          library,
          sessionCount,
          totalSeconds,
        );
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Reading Statistics',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh statistics',
                      onPressed: () => setState(() {}),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (sessionCount == 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 64),
                    child: Center(
                      child: Text(
                        'No reading sessions yet — open a book in the reader.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _SummaryCard(
                        label: 'Reading time',
                        value: _formatDuration(totalSeconds),
                      ),
                      _SummaryCard(
                        label: 'Books read',
                        value: '$booksRead',
                      ),
                      _SummaryCard(
                        label: 'Sessions',
                        value: '$sessionCount',
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text('Recent sessions', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  _RecentSessionsList(
                    sessions: recent,
                    bookTitle: (id) {
                      final title = appState.bookById(id)?.title ?? '';
                      return title.isEmpty ? 'Unknown book' : title;
                    },
                  ),
                  const SizedBox(height: 24),
                  Text('By book', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  _PerBookStatsList(stats: perBook),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  List<_BookStat> _perBookStats(
      Library library, int sessionCount, int totalSeconds) {
    if (sessionCount == 0) return const <_BookStat>[];
    if (!identical(library, _cachedLibrary) ||
        sessionCount != _cachedSessions ||
        totalSeconds != _cachedTotalSeconds) {
      final data = <int, _BookStatData>{};
      for (final book in library.allBooks(includeHidden: true)) {
        final bookId = book.id;
        if (bookId == null) continue;
        final stats = library.statsForBook(bookId);
        final sessions = (stats['sessions'] as num?)?.toInt() ?? 0;
        if (sessions == 0) continue;
        data[bookId] = _BookStatData(
          totalSeconds: (stats['totalSeconds'] as num?)?.toInt() ?? 0,
          sessions: sessions,
          lastRead: stats['lastRead'] as String? ?? '',
        );
      }
      _cachedData = data;
      _cachedLibrary = library;
      _cachedSessions = sessionCount;
      _cachedTotalSeconds = totalSeconds;
    }
    final result = <_BookStat>[];
    for (final book in library.allBooks(includeHidden: true)) {
      final bookId = book.id;
      final data = bookId == null ? null : _cachedData[bookId];
      if (data == null) continue;
      result.add(
        _BookStat(
          book: book,
          totalSeconds: data.totalSeconds,
          sessions: data.sessions,
          lastRead: data.lastRead,
        ),
      );
    }
    result.sort((a, b) => b.totalSeconds.compareTo(a.totalSeconds));
    return result;
  }
}

class _BookStatData {
  const _BookStatData({
    required this.totalSeconds,
    required this.sessions,
    required this.lastRead,
  });

  final int totalSeconds;
  final int sessions;
  final String lastRead;
}

class _BookStat {
  const _BookStat({
    required this.book,
    required this.totalSeconds,
    required this.sessions,
    required this.lastRead,
  });

  final Book book;
  final int totalSeconds;
  final int sessions;
  final String lastRead;
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 200,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(value, style: theme.textTheme.headlineSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentSessionsList extends StatelessWidget {
  const _RecentSessionsList({required this.sessions, required this.bookTitle});

  final List<Map<String, Object?>> sessions;
  final String Function(int bookId) bookTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (sessions.isEmpty) {
      return Text(
        'No recent sessions',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < sessions.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _RecentSessionTile(
              session: sessions[i],
              bookTitle: bookTitle(
                (sessions[i]['book_id'] as num?)?.toInt() ?? -1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecentSessionTile extends StatelessWidget {
  const _RecentSessionTile({required this.session, required this.bookTitle});

  final Map<String, Object?> session;
  final String bookTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final started = _formatDateTime(session['started'] as String? ?? '');
    final duration = _formatDuration(
      (session['duration_seconds'] as num?)?.toInt() ?? 0,
    );
    final locator = session['end_locator'] as String? ?? '';
    return ListTile(
      dense: true,
      title: Text(
        bookTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$started · $duration'),
          if (locator.isNotEmpty)
            Text(
              locator,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _PerBookStatsList extends StatelessWidget {
  const _PerBookStatsList({required this.stats});

  final List<_BookStat> stats;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) {
      return const Text('No per-book statistics');
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _PerBookStatTile(stat: stats[i]),
          ],
        ],
      ),
    );
  }
}

class _PerBookStatTile extends StatelessWidget {
  const _PerBookStatTile({required this.stat});

  final _BookStat stat;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      _formatDuration(stat.totalSeconds),
      '${stat.sessions} sessions',
    ];
    if (stat.lastRead.isNotEmpty) {
      parts.add('Last read ${_formatDateTime(stat.lastRead)}');
    }
    return ListTile(
      dense: true,
      title: Text(
        stat.book.title.isEmpty ? 'Untitled' : stat.book.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(parts.join(' · ')),
    );
  }
}

String _formatDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

String _formatDateTime(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/db.dart';
import '../core/models.dart';
import 'theme.dart';

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
        final palette = context.palette;
        final library = appState.library;
        final summary = library.libraryStats();
        final totalSeconds = (summary['totalSeconds'] as num?)?.toInt() ?? 0;
        final booksRead = (summary['booksRead'] as num?)?.toInt() ?? 0;
        final sessionCount = (summary['sessions'] as num?)?.toInt() ?? 0;
        final recent = appState.stats.recentSessions(50);
        final perBook = _perBookStats(library, sessionCount, totalSeconds);
        return ColoredBox(
          color: palette.background,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  VellumSpace.xl,
                  VellumSpace.lg,
                  VellumSpace.xl,
                  VellumSpace.xxl,
                ),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Reading Statistics',
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
                              'Time kept from the books you open.',
                              style: VellumType.ui(
                                12.5,
                                color: palette.textDim,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh statistics',
                        onPressed: () => setState(() {}),
                        icon: const Icon(Icons.refresh, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: VellumSpace.lg),
                  if (sessionCount == 0)
                    _empty(palette)
                  else ...[
                    _SummaryStrip(
                      totalSeconds: totalSeconds,
                      booksRead: booksRead,
                      sessionCount: sessionCount,
                    ),
                    const SizedBox(height: VellumSpace.xl),
                    _SectionHeader(
                      title: 'Recent sessions',
                      detail: recent.length == 1
                          ? '1 session'
                          : '${recent.length} sessions',
                    ),
                    const SizedBox(height: VellumSpace.xs),
                    _RecentSessions(
                      sessions: recent,
                      bookTitle: (id) {
                        final title = appState.bookById(id)?.title ?? '';
                        return title.isEmpty ? 'Unknown book' : title;
                      },
                    ),
                    const SizedBox(height: VellumSpace.xl),
                    _SectionHeader(
                      title: 'By book',
                      detail: perBook.length == 1
                          ? '1 book'
                          : '${perBook.length} books',
                    ),
                    const SizedBox(height: VellumSpace.xs),
                    _PerBookStats(stats: perBook),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _empty(VellumPalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Center(
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
              child: Icon(Icons.schedule, size: 23, color: palette.textDim),
            ),
            const SizedBox(height: VellumSpace.md),
            Text(
              'No reading sessions yet — open a book in the reader.',
              textAlign: TextAlign.center,
              style: VellumType.ui(13, height: 1.5, color: palette.textDim),
            ),
          ],
        ),
      ),
    );
  }

  List<_BookStat> _perBookStats(
    Library library,
    int sessionCount,
    int totalSeconds,
  ) {
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

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.totalSeconds,
    required this.booksRead,
    required this.sessionCount,
  });

  final int totalSeconds;
  final int booksRead;
  final int sessionCount;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final metrics = [
      ('Reading time', _formatDuration(totalSeconds)),
      ('Books read', '$booksRead'),
      ('Sessions', '$sessionCount'),
    ];
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VellumSpace.lg,
        vertical: VellumSpace.lg,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A narrow window cannot hold three large numerals in one row
          // without one of them breaking mid-number; use a ledger instead.
          if (constraints.maxWidth < 520) {
            return Column(
              children: [
                for (var i = 0; i < metrics.length; i++) ...[
                  if (i > 0)
                    Divider(height: VellumSpace.lg, color: palette.line),
                  _MetricLine(label: metrics[i].$1, value: metrics[i].$2),
                ],
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              children: [
                for (var i = 0; i < metrics.length; i++) ...[
                  if (i > 0) _divider(palette),
                  Expanded(
                    child: _Metric(
                      label: metrics[i].$1,
                      value: metrics[i].$2,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _divider(VellumPalette palette) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: VellumSpace.lg),
    child: VerticalDivider(width: 1, color: palette.line),
  );
}

class _MetricLine extends StatelessWidget {
  const _MetricLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: VellumType.ui(
              11,
              weight: FontWeight.w500,
              height: 1.2,
              color: palette.textDim,
            ),
          ),
        ),
        Text(
          value,
          textAlign: TextAlign.right,
          style: VellumType.display(
            24,
            weight: FontWeight.w600,
            height: 1,
            letterSpacing: -0.3,
            color: palette.text,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: VellumType.ui(
            11,
            weight: FontWeight.w500,
            height: 1.2,
            color: palette.textDim,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: VellumType.display(
            30,
            weight: FontWeight.w600,
            height: 1,
            letterSpacing: -0.4,
            color: palette.text,
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            title,
            style: VellumType.display(
              20,
              weight: FontWeight.w600,
              height: 1.2,
              color: palette.text,
            ),
          ),
        ),
        Text(detail, style: VellumType.ui(11.5, color: palette.textDim)),
      ],
    );
  }
}

class _RecentSessions extends StatelessWidget {
  const _RecentSessions({required this.sessions, required this.bookTitle});

  final List<Map<String, Object?>> sessions;
  final String Function(int bookId) bookTitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (sessions.isEmpty) {
      return Text(
        'No recent sessions',
        style: VellumType.ui(13, color: palette.textDim),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: sessions.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: palette.line),
        itemBuilder: (context, index) {
          final session = sessions[index];
          return _RecentSessionTile(
            session: session,
            bookTitle: bookTitle((session['book_id'] as num?)?.toInt() ?? -1),
          );
        },
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
    final palette = context.palette;
    final started = _formatDateTime(session['started'] as String? ?? '');
    final duration = _formatDuration(
      (session['duration_seconds'] as num?)?.toInt() ?? 0,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VellumSpace.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 138,
            child: Text(
              started,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VellumType.ui(11.5, color: palette.textDim),
            ),
          ),
          const SizedBox(width: VellumSpace.sm),
          Expanded(
            child: Text(
              bookTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VellumType.ui(
                13,
                weight: FontWeight.w500,
                color: palette.text,
              ),
            ),
          ),
          const SizedBox(width: VellumSpace.sm),
          Text(duration, style: VellumType.ui(12.5, color: palette.textDim)),
        ],
      ),
    );
  }
}

class _PerBookStats extends StatelessWidget {
  const _PerBookStats({required this.stats});

  final List<_BookStat> stats;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (stats.isEmpty) {
      return Text(
        'No per-book statistics',
        style: VellumType.ui(13, color: palette.textDim),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: stats.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: palette.line),
        itemBuilder: (context, index) => _PerBookStatTile(stat: stats[index]),
      ),
    );
  }
}

class _PerBookStatTile extends StatelessWidget {
  const _PerBookStatTile({required this.stat});

  final _BookStat stat;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final parts = <String>[
      _formatDuration(stat.totalSeconds),
      '${stat.sessions} sessions',
    ];
    if (stat.lastRead.isNotEmpty) {
      parts.add('Last read ${_formatDateTime(stat.lastRead)}');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VellumSpace.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              stat.book.title.isEmpty ? 'Untitled' : stat.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: VellumType.ui(
                13,
                weight: FontWeight.w500,
                color: palette.text,
              ),
            ),
          ),
          const SizedBox(width: VellumSpace.sm),
          Text(
            parts.join(' · '),
            style: VellumType.ui(12, color: palette.textDim),
          ),
        ],
      ),
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
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, $hh:$mm';
}

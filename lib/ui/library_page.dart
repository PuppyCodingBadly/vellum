/// Library grid with full-text content search results.
///
/// Ports `vellum/ui/library_view.py`; the "In book text" section exposes the
/// port's full-text search over book contents.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'book_details_page.dart';
import 'reader_page.dart';
import 'widgets/book_cover.dart';

/// Grid of every book in the current view.
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => _buildContent(context, state),
    );
  }

  Widget _buildContent(BuildContext context, AppState state) {
    final query = state.searchQuery.trim();
    final hasQuery = query.isNotEmpty;
    final hits = hasQuery ? _contentHits(state, query) : const <_ContentHit>[];

    final grid = state.books.isEmpty
        ? (hasQuery
            ? Center(
                child: Text(
                  hits.isEmpty
                      ? 'No results for “$query”.'
                      : 'No matching titles for “$query”.',
                ),
              )
            : const Center(child: Text('No books in your library yet.')))
        : GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              childAspectRatio: 2 / 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: state.books.length,
            itemBuilder: (context, index) {
              final book = state.books[index];
              return BookCard(
                book: book,
                onTap: () => _openBook(context, book),
              );
            },
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hits.isNotEmpty) _ContentSection(hits: hits),
        Expanded(child: grid),
      ],
    );
  }

  /// Up to 20 full-text hits restricted to books in the library.
  List<_ContentHit> _contentHits(AppState state, String query) {
    final allBooks = state.library.allBooks(includeHidden: state.showHidden);
    final visible = <int, Book>{
      for (final book in allBooks)
        if (book.id != null) book.id!: book,
    };
    final hits = <_ContentHit>[];
    for (final row in state.searchBookContents(query)) {
      if (hits.length >= 20) break;
      final id = row['book_id'];
      if (id is! int) continue;
      final book = visible[id];
      if (book == null) continue;
      if (book.hidden && !state.showHidden) continue;
      final chapter = row['chapter'];
      hits.add(
        _ContentHit(
          book: book,
          chapter: chapter is int ? chapter : int.tryParse('$chapter'),
          chapterTitle: (row['title'] ?? '').toString(),
          snippet: (row['snippet'] ?? '')
              .toString()
              .replaceAll('<b>', '')
              .replaceAll('</b>', ''),
        ),
      );
    }
    return hits;
  }

  void _openBook(BuildContext context, Book book) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BookDetailsPage(book: book),
      ),
    );
  }
}

/// One full-text search hit inside a book.
class _ContentHit {
  const _ContentHit({
    required this.book,
    required this.chapter,
    required this.chapterTitle,
    required this.snippet,
  });

  final Book book;
  final int? chapter;
  final String chapterTitle;
  final String snippet;
}

/// "In book text" list shown above the grid while a query is active.
class _ContentSection extends StatelessWidget {
  const _ContentSection({required this.hits});

  final List<_ContentHit> hits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('In book text', style: theme.textTheme.titleSmall),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: hits.length,
              itemBuilder: (context, index) {
                final hit = hits[index];
                final title = hit.book.title.isEmpty
                    ? 'Untitled'
                    : hit.book.title;
                return ListTile(
                  dense: true,
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hit.chapterTitle.isNotEmpty)
                        Text(
                          hit.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        hit.snippet,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => ReaderPage(
                        book: hit.book,
                        initialChapter: hit.chapter,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

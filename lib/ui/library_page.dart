/// The library: a cover wall, search, and full-text hits.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import '../core/sorting.dart';
import 'book_details_page.dart';
import 'reader_page.dart';
import 'theme.dart';
import 'widgets/book_grid.dart';

/// Grid of every book in the current view, with content-search results.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce;

  bool _restoredQuery = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredQuery) return;
    _restoredQuery = true;
    _search.text = AppState.of(context).searchQuery;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Focuses the search field; the app-level Ctrl+F shortcut lands here.
  void focusSearch({bool selectAll = false}) {
    _searchFocus.requestFocus();
    if (selectAll) {
      _search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _search.text.length,
      );
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(AppState.of(context).setSearchQuery(_search.text));
    });
  }

  void _submitSearch(String value) {
    _searchDebounce?.cancel();
    unawaited(AppState.of(context).setSearchQuery(value));
  }

  void _openBook(Book book) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BookDetailsPage(book: book),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => _buildContent(context, state),
    );
  }

  Widget _buildContent(BuildContext context, AppState state) {
    final palette = context.palette;
    final query = state.searchQuery.trim();
    final hasQuery = query.isNotEmpty;
    final hits = hasQuery ? _contentHits(state, query) : const <_ContentHit>[];

    return ColoredBox(
      color: palette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context, state, hasQuery: hasQuery),
          if (hits.isNotEmpty) _ContentSection(hits: hits),
          Expanded(
            child: state.books.isEmpty
                ? _empty(
                    context,
                    state,
                    query: query,
                    hasQuery: hasQuery,
                    hits: hits,
                  )
                : BookGrid(books: state.books, onTap: _openBook),
          ),
        ],
      ),
    );
  }

  Widget _header(
    BuildContext context,
    AppState state, {
    required bool hasQuery,
  }) {
    final palette = context.palette;
    final count = state.books.length;
    final countLabel = count == 1 ? '1 book' : '$count books';
    final sortLabel = SORT_OPTIONS
        .firstWhere(
          (option) => option.$1 == state.sortKey,
          orElse: () => ('title', 'Title'),
        )
        .$2;
    final query = state.searchQuery.trim();
    final subtitle = hasQuery
        ? '$countLabel matching “$query”'
        : '$countLabel · sorted by ${sortLabel.toLowerCase()}';

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Library',
          style: VellumType.display(
            32,
            weight: FontWeight.w600,
            height: 1.08,
            letterSpacing: -0.5,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          subtitle,
          style: VellumType.ui(12.5, height: 1.4, color: palette.textDim),
        ),
      ],
    );

    final search = SizedBox(
      width: 320,
      height: 38,
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onChanged: (value) {
          setState(() {});
          _onSearchChanged(value);
        },
        onSubmitted: _submitSearch,
        style: VellumType.ui(13, height: 1.35, color: palette.text),
        cursorHeight: 16,
        decoration: InputDecoration(
          hintText: 'Search library…',
          hintStyle: VellumType.ui(13, color: palette.textDim),
          prefixIconColor: palette.textDim,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          prefixIcon: const Icon(Icons.search, size: 17),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 38,
            minHeight: 38,
          ),
          suffixIcon: _search.text.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    'Ctrl F',
                    style: VellumType.ui(
                      10.5,
                      weight: FontWeight.w500,
                      color: palette.textDim.withValues(alpha: 0.75),
                    ),
                  ),
                )
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () {
                    _search.clear();
                    unawaited(state.setSearchQuery(''));
                  },
                ),
        ),
      ),
    );

    final sort = Tooltip(
      message: 'Sort library',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: state.sortKey,
          borderRadius: VellumRadius.largeAll,
          dropdownColor: palette.surface,
          icon: const Icon(Icons.unfold_more, size: 15),
          style: VellumType.ui(
            12.5,
            weight: FontWeight.w500,
            color: palette.textDim,
          ),
          items: [
            for (final (key, label) in SORT_OPTIONS)
              DropdownMenuItem<String>(value: key, child: Text(label)),
          ],
          onChanged: (key) {
            if (key != null) unawaited(state.setSortKey(key));
          },
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VellumSpace.xl,
        VellumSpace.lg,
        VellumSpace.xl,
        VellumSpace.md,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 700) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: VellumSpace.md),
                Row(
                  children: [
                    Expanded(child: search),
                    const SizedBox(width: 6),
                    sort,
                  ],
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: title),
              search,
              const SizedBox(width: 8),
              sort,
            ],
          );
        },
      ),
    );
  }

  Widget _empty(
    BuildContext context,
    AppState state, {
    required String query,
    required bool hasQuery,
    required List<_ContentHit> hits,
  }) {
    final palette = context.palette;
    final heading = hasQuery
        ? (hits.isEmpty
              ? 'No results for “$query”.'
              : 'No matching titles for “$query”.')
        : 'No books in your library yet.';
    final description = hasQuery
        ? 'Try a different title, author, ISBN, or a word from the book text.'
        : 'Import a calibre library or add books from a store plugin to begin.';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VellumSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: palette.surfaceHigh,
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.line),
                ),
                child: Icon(
                  hasQuery
                      ? Icons.search_off_outlined
                      : Icons.menu_book_outlined,
                  size: 25,
                  color: palette.textDim,
                ),
              ),
              const SizedBox(height: VellumSpace.md),
              Text(
                heading,
                textAlign: TextAlign.center,
                style: VellumType.display(
                  23,
                  weight: FontWeight.w600,
                  height: 1.2,
                  color: palette.text,
                ),
              ),
              const SizedBox(height: VellumSpace.xs),
              Text(
                description,
                textAlign: TextAlign.center,
                style: VellumType.ui(13, height: 1.55, color: palette.textDim),
              ),
              if (!hasQuery) ...[
                const SizedBox(height: VellumSpace.lg),
                FilledButton.icon(
                  onPressed: () => unawaited(state.chooseAndImportCalibre()),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Import calibre library'),
                ),
              ],
            ],
          ),
        ),
      ),
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

/// "In book text" results shown above the cover wall while a query is active.
class _ContentSection extends StatefulWidget {
  const _ContentSection({required this.hits});

  final List<_ContentHit> hits;

  @override
  State<_ContentSection> createState() => _ContentSectionState();
}

class _ContentSectionState extends State<_ContentSection> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hits = widget.hits;
    return Container(
      // The header plus two complete rows. The scrollbar says the rest is
      // there, so the wall keeps enough room to be useful during a search.
      constraints: const BoxConstraints(maxHeight: 214),
      margin: const EdgeInsets.fromLTRB(
        VellumSpace.xl,
        VellumSpace.xs,
        VellumSpace.xl,
        VellumSpace.sm,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: VellumRadius.largeAll,
        border: Border.all(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'In book text',
                    style: VellumType.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                ),
                Text(
                  hits.length == 1 ? '1 match' : '${hits.length} matches',
                  style: VellumType.ui(11, color: palette.textDim),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: palette.line),
          Flexible(
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: ListView.separated(
                controller: _scroll,
                padding: const EdgeInsets.only(right: 8),
                itemCount: hits.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: palette.line.withValues(alpha: 0.7),
                ),
                itemBuilder: (context, index) {
                  final hit = hits[index];
                  final title =
                      hit.book.title.isEmpty ? 'Untitled' : hit.book.title;
                  return InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => ReaderPage(
                          book: hit.book,
                          initialChapter: hit.chapter,
                        ),
                      ),
                    ),
                    child: SizedBox(
                      height: 86,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                Icons.notes,
                                size: 15,
                                color: palette.textDim,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: VellumType.ui(
                                      13,
                                      weight: FontWeight.w600,
                                      height: 1.3,
                                      color: palette.text,
                                    ),
                                  ),
                                  if (hit.chapterTitle.isNotEmpty)
                                    Text(
                                      hit.chapterTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: VellumType.ui(
                                        11,
                                        color: palette.textDim,
                                      ),
                                    ),
                                  Text(
                                    hit.snippet,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: VellumType.ui(
                                      12,
                                      height: 1.45,
                                      color: palette.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

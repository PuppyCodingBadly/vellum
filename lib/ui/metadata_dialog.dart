import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/covers.dart';
import '../core/isbn.dart';
import '../core/models.dart';
import '../metadata/engine.dart';
import '../metadata/metadata.dart';
import '../metadata/sorting.dart';
import '../metadata/universal.dart' show normalizeUrl;
import 'theme.dart';
import 'widgets/book_cover.dart';

/// Modal dialog that searches metadata sources and applies a chosen result.
class MetadataDialog extends StatefulWidget {
  const MetadataDialog({super.key, required this.book});

  /// The book whose metadata is being edited.
  final Book book;

  @override
  State<MetadataDialog> createState() => _MetadataDialogState();
}

enum _View { busy, results, empty }

class _MetadataDialogState extends State<MetadataDialog> {
  final TextEditingController _queryController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();

  bool _started = false;
  bool _applying = false;
  _View _view = _View.busy;
  String _busyMessage = 'Searching metadata sources…';
  String _emptyTitle = 'No Results';
  String _emptyDescription = 'No metadata source returned a match.';
  List<Metadata> _results = [];
  Metadata? _selected;
  String _sortKey = 'relevance';
  int _serial = 0;

  /// Generation of the pending apply; dismissing the dialog bumps it so an
  /// apply that is still waiting on the cover never saves or toasts.
  int _applySerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _started) return;
      _started = true;
      _autoSearch();
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  int _beginRequest(String message) {
    final serial = ++_serial;
    setState(() {
      _busyMessage = message;
      _view = _View.busy;
      _results = [];
      _selected = null;
    });
    return serial;
  }

  Future<void> _autoSearch() async {
    final app = AppState.of(context);
    final book = widget.book;
    final authors = book.authors.isEmpty ? null : List.of(book.authors);
    final serial = _beginRequest('Searching metadata sources…');
    try {
      final searches = await Future.wait([
        app.engine.find(title: book.title, authors: authors, isbn: book.isbn),
        _searchPlugins(
          app,
          title: book.title,
          authors: authors,
          isbn: book.isbn,
        ),
      ]);
      if (!mounted || serial != _serial) return;
      final results = MetadataEngine.combineSources([
        ...searches[0],
        ...searches[1],
      ]);
      _showSearchResults(results, matchedQuery: false);
    } catch (error) {
      if (!mounted || serial != _serial) return;
      _showFailure('Search Failed', 'Metadata search failed: $error', app);
    }
  }

  Future<void> _runQuery() async {
    final app = AppState.of(context);
    final query = _queryController.text.trim();
    if (query.isEmpty) {
      app.showToast('Enter a title, author, or ISBN to search');
      return;
    }
    final serial = _beginRequest('Searching metadata sources…');
    try {
      final searches = await Future.wait([
        app.engine.findQuery(query),
        _searchPlugins(app, title: query, isbn: queryIsbn(query)),
      ]);
      if (!mounted || serial != _serial) return;
      final builtIns = searches[0]
          .where((meta) => meta.sourceId != 'merged')
          .toList();
      final results = MetadataEngine.combineQuery(query, [
        ...builtIns,
        ...searches[1],
      ]);
      _showSearchResults(results, matchedQuery: true);
    } catch (error) {
      if (!mounted || serial != _serial) return;
      _showFailure('Search Failed', 'Metadata search failed: $error', app);
    }
  }

  /// Searches loaded calibre metadata plugins.  Plugin failures are isolated
  /// so a broken plugin never sinks the whole search.
  Future<List<Metadata>> _searchPlugins(
    AppState app, {
    String title = '',
    List<String>? authors,
    String isbn = '',
  }) async {
    try {
      final rows = await app.plugins.metadataSearch(
        title: title,
        authors: authors,
        isbn: isbn,
      );
      return [for (final row in rows) Metadata.fromJson(row)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _grabUrl() async {
    final app = AppState.of(context);
    final text = _urlController.text.trim();
    if (text.isEmpty) {
      app.showToast('Paste a book page URL first');
      return;
    }
    final url = normalizeUrl(text);
    if (url.isEmpty) {
      // Not a URL: treat the input as a fuzzy search query.
      _queryController.text = text;
      await _runQuery();
      return;
    }
    final serial = _beginRequest('Reading book page…');
    try {
      final meta = await app.engine.grabUrl(url);
      if (!mounted || serial != _serial) return;
      if (meta == null) {
        setState(() {
          _results = [];
          _selected = null;
          _view = _View.empty;
          _emptyTitle = 'No Metadata Found';
          _emptyDescription =
              'The page did not contain recognizable book metadata.';
        });
        return;
      }
      setState(() {
        _results = [meta];
        _selected = meta;
        _view = _View.results;
      });
    } catch (error) {
      if (!mounted || serial != _serial) return;
      _showFailure('Grab Failed', 'Could not read that page: $error', app);
    }
  }

  void _showSearchResults(
    List<Metadata> results, {
    required bool matchedQuery,
  }) {
    if (results.isEmpty) {
      setState(() {
        _results = [];
        _selected = null;
        _view = _View.empty;
        _emptyTitle = 'No Results';
        _emptyDescription = matchedQuery
            ? 'No metadata source matched that string.'
            : 'No metadata source returned a match.';
      });
      return;
    }
    setState(() {
      _results = List.of(results);
      _selected = null;
      _view = _View.results;
    });
  }

  void _showFailure(String title, String description, AppState app) {
    app.showToast(description);
    setState(() {
      _results = [];
      _selected = null;
      _view = _View.empty;
      _emptyTitle = title;
      _emptyDescription = description;
    });
  }

  /// Fetches cover bytes for [meta], preferring the plugin that produced it.
  Future<Uint8List?> _coverBytes(AppState app, Metadata meta) async {
    final pluginResult = app.plugins.metadataPlugins().any(
      (plugin) => plugin.name == meta.sourceName,
    );
    if (pluginResult) {
      try {
        final data = await app.plugins.downloadCover(meta.toJson());
        if (data != null && data.isNotEmpty) return data;
      } catch (_) {
        // Fall through to the built-in engine.
      }
    }
    return app.engine.fetchCover(meta);
  }

  Future<void> _apply() async {
    final meta = _selected;
    if (meta == null || _applying) return;
    final app = AppState.of(context);
    final serial = ++_applySerial;
    setState(() => _applying = true);

    // Build the new row in a copy: the instance the caller passed in is only
    // touched after the save succeeds, so a cancelled apply cannot leave it
    // showing metadata the library never stored.
    final updated = widget.book.copyWith();
    _applyMetadata(updated, meta);

    // Cover download is best-effort: a failure is reported with the rest of
    // the outcome but does not block the textual metadata.
    String? coverError;
    Uint8List? coverBytes;
    try {
      final data = await _coverBytes(app, meta);
      if (!_stillApplying(serial)) return;
      if (data != null && data.isNotEmpty) coverBytes = data;
    } catch (error) {
      coverError = '$error';
    }
    if (!_stillApplying(serial)) return;

    try {
      final bookId = updated.id;
      if (coverBytes == null || bookId == null) {
        app.library.updateBook(updated);
      } else {
        try {
          await replaceCover(
            dataDir: app.dataDir,
            bookId: bookId,
            bytes: coverBytes,
            // The row must name the final path before the cover lands there,
            // so a refusal here leaves the previous artwork in place.
            saveBook: (coverPath) {
              updated.coverPath = coverPath;
              app.library.updateBook(updated);
            },
          );
        } on CoverWriteException catch (error) {
          // Unusable artwork: keep the book's existing cover, save the rest.
          coverError ??= '$error';
          app.library.updateBook(updated);
        }
      }
    } catch (error) {
      app.showToast('Failed to save book: $error');
      if (mounted) setState(() => _applying = false);
      return;
    }
    _applyMetadata(widget.book, meta);
    widget.book.coverPath = updated.coverPath;
    if (updated.id != null) BookCover.invalidate(updated.id!);

    await app.refresh();
    if (!mounted) return;
    if (!_stillApplying(serial)) return;
    app.showToast(
      coverError == null
          ? 'Metadata applied'
          : 'Metadata applied without cover: $coverError',
    );
    Navigator.of(context).pop(true);
  }

  bool _stillApplying(int serial) => mounted && serial == _applySerial;

  /// Dismisses the dialog and invalidates any apply still in flight.
  void _close() {
    _applySerial++;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Barrier and Escape dismissal take the same cancel path as Close, so
      // the apply token is bumped before the route goes away.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 660,
          height: 600,
          child: Column(
            children: [
              _buildHeader(context),
              const Divider(height: 1),
              _buildQueryBar(context),
              _buildUrlBar(context),
              Expanded(child: _buildView(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Fetch Metadata',
              style: VellumType.display(
                22,
                weight: FontWeight.w600,
                height: 1.2,
                color: context.palette.text,
              ),
            ),
          ),
          FilledButton(
            onPressed: _selected != null && !_applying ? _apply : null,
            child: Text(_applying ? 'Applying…' : 'Apply'),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: _close,
          ),
        ],
      ),
    );
  }

  Widget _buildQueryBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _queryController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runQuery(),
              decoration: const InputDecoration(
                hintText: 'Search metadata by title, author, or ISBN…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _runQuery, child: const Text('Search')),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Sort results',
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _sortKey,
                isDense: true,
                items: [
                  for (final (key, label) in resultSortOptions)
                    DropdownMenuItem(value: key, child: Text(label)),
                ],
                onChanged: (key) {
                  if (key == null) return;
                  setState(() => _sortKey = key);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _urlController,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _grabUrl(),
              decoration: const InputDecoration(
                hintText: 'Paste a book page URL…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _grabUrl, child: const Text('Grab')),
        ],
      ),
    );
  }

  Widget _buildView(BuildContext context) {
    final theme = Theme.of(context);
    switch (_view) {
      case _View.busy:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(),
              ),
              const SizedBox(height: 12),
              Text(
                _busyMessage,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      case _View.empty:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.search_off,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(_emptyTitle, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  _emptyDescription,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      case _View.results:
        final sorted = sortMetadata(_results, _sortKey);
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (context, index) {
            final meta = sorted[index];
            return _ResultTile(
              meta: meta,
              selected: identical(meta, _selected),
              onTap: () => setState(() => _selected = meta),
            );
          },
        );
    }
  }
}

/// Copies every non-empty field of [meta] onto [book].
///
/// The single rule shared by the saved copy and the caller-visible instance
/// updated after the save.
void _applyMetadata(Book book, Metadata meta) {
  if (meta.title.isNotEmpty) book.title = meta.title;
  if (meta.authors.isNotEmpty) book.authors = List.of(meta.authors);
  if (meta.isbn.isNotEmpty) book.isbn = meta.isbn;
  if (meta.publisher.isNotEmpty) book.publisher = meta.publisher;
  if (meta.pubdate.isNotEmpty) book.pubdate = meta.pubdate;
  if (meta.language.isNotEmpty) book.language = meta.language;
  if (meta.description.isNotEmpty) book.description = meta.description;
  if (meta.tags.isNotEmpty) book.tags = List.of(meta.tags);
  if (meta.rating > 0) book.rating = meta.rating;
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.meta,
    required this.selected,
    required this.onTap,
  });

  final Metadata meta;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final authors = meta.authors.isEmpty
        ? 'Unknown author'
        : meta.authors.join(', ');
    final source = meta.sourceName.isNotEmpty
        ? meta.sourceName
        : (meta.sourceId.isNotEmpty ? meta.sourceId : 'Unknown source');
    final origin = meta.isbn.isEmpty ? source : '$source · ISBN ${meta.isbn}';

    final palette = context.palette;
    return Material(
      color: selected ? palette.surfaceHigh : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: VellumRadius.mediumAll,
        side: BorderSide(
          color: selected
              ? palette.accent.withValues(alpha: 0.45)
              : Colors.transparent,
        ),
      ),
      child: InkWell(
        borderRadius: VellumRadius.mediumAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _buildCover(theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      meta.title.isEmpty ? 'Untitled' : meta.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      authors,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dim,
                    ),
                    Text(
                      origin,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: dim,
                    ),
                  ],
                ),
              ),
              if (meta.rating > 0) ...[
                const SizedBox(width: 8),
                Icon(Icons.star_rounded, size: 14, color: palette.accentSoft),
                const SizedBox(width: 3),
                Text(
                  meta.rating.toStringAsFixed(1),
                  style: VellumType.ui(12, color: palette.textDim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ThemeData theme) {
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return SizedBox(
      width: 48,
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: meta.coverUrl.isEmpty
            ? placeholder
            : Image.network(
                meta.coverUrl,
                width: 48,
                height: 72,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder,
              ),
      ),
    );
  }
}

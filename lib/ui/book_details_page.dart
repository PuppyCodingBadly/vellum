import 'dart:io';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/models.dart';
import 'metadata_dialog.dart';
import 'reader_page.dart';
import 'widgets/book_cover.dart';

/// Full-page view of a single book with cover, metadata, and actions.
class BookDetailsPage extends StatefulWidget {
  const BookDetailsPage({super.key, required this.book});

  /// The book to display. Refreshed from the library on state changes.
  final Book book;

  @override
  State<BookDetailsPage> createState() => _BookDetailsPageState();
}

class _BookDetailsPageState extends State<BookDetailsPage> {
  static const Set<String> _readableFormats = {'epub', 'pdf', 'mobi'};

  late Book _book;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppState.of(context);
    _appState = app;
    // AppState is provided via InheritedNotifier, so this runs on every
    // notification: keep the local book in sync with the database.
    final id = _book.id;
    if (id == null) return;
    final fresh = app.bookById(id);
    if (fresh != null && !identical(fresh, _book)) {
      _book = fresh;
    }
  }

  bool get _canRead =>
      _book.formats.any((format) => _readableFormats.contains(format.toLowerCase())) &&
      _book.path.isNotEmpty &&
      File(_book.path).existsSync();

  Future<void> _fetchMetadata() async {
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => MetadataDialog(book: _book),
    );
    if (!mounted || applied != true) return;
    final app = _appState;
    final id = _book.id;
    final fresh = (app != null && id != null) ? app.bookById(id) : null;
    setState(() {
      if (fresh != null) _book = fresh;
    });
  }

  void _openReader() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReaderPage(book: _book)),
    );
  }

  Future<void> _toggleHidden() async {
    final app = _appState;
    if (app == null) return;
    final hidden = !_book.hidden;
    await app.setBookHidden(_book, hidden);
    if (!mounted) return;
    setState(() => _book = _book.copyWith(hidden: hidden));
    app.showToast(hidden ? 'Book hidden' : 'Book shown');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _book.title.isEmpty ? 'Untitled' : _book.title;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 24,
                children: [
                  _buildHeader(theme),
                  _buildDetails(theme),
                  _buildDescription(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final authors = _book.authors.isEmpty
        ? 'Unknown author'
        : _book.authors.join(', ');
    final rating = _book.rating;
    final filledStars = rating.round().clamp(0, 5).toInt();
    final stars = '★' * filledStars + '☆' * (5 - filledStars);
    final ratingText = rating > 0 ? '$stars  ${rating.toStringAsFixed(1)}' : stars;
    final accent = _appState?.accentColor ?? theme.colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookCover(book: _book, width: 220, height: 330),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _book.title.isEmpty ? 'Untitled' : _book.title,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                authors,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(ratingText, style: theme.textTheme.bodyLarge),
              if (_book.tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _book.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          tag,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: accent),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _fetchMetadata,
                    child: const Text('Fetch Metadata'),
                  ),
                  if (_canRead)
                    FilledButton(
                      onPressed: _openReader,
                      child: const Text('Read'),
                    ),
                  OutlinedButton(
                    onPressed: _toggleHidden,
                    child: Text(_book.hidden ? 'Unhide Book' : 'Hide Book'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetails(ThemeData theme) {
    final rows = <(String, String)>[
      ('Publisher', _book.publisher),
      ('Published', _book.pubdate),
      ('Language', _book.language),
      ('ISBN', _book.isbn),
    ].where((row) => row.$2.isNotEmpty).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    final labelStyle = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Details', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(label, style: labelStyle),
                ),
                Expanded(
                  child: Text(value, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDescription(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Description', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          _book.description.isEmpty
              ? 'No description available.'
              : _book.description,
        ),
      ],
    );
  }
}

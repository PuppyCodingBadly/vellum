import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/cover_generator.dart';
import '../core/models.dart';
import 'cover_generator_dialog.dart';
import 'metadata_dialog.dart';
import 'reader_page.dart';
import 'theme.dart';
import 'widgets/book_cover.dart';

/// Full-page view of a single book: the cover, its facts, and the actions.
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
      _book.formats.any(
        (format) => _readableFormats.contains(format.toLowerCase()),
      ) &&
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

  Future<void> _openReader() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ReaderPage(book: _book)));
    if (!mounted) return;
    final app = _appState;
    final id = _book.id;
    if (app == null || id == null) return;
    await app.refresh();
    final fresh = app.bookById(id);
    if (fresh != null && mounted) setState(() => _book = fresh);
  }

  Future<void> _generateCover() async {
    final app = _appState;
    final id = _book.id;
    if (app == null || id == null) return;
    final png = await showDialog<Uint8List>(
      context: context,
      builder: (context) => CoverGeneratorDialog(book: _book),
    );
    if (png == null || !mounted) return;
    try {
      final path = await writeGeneratedCover(
        dataDir: app.dataDir,
        bookId: id,
        png: png,
      );
      final updated = _book.copyWith(coverPath: path);
      app.library.updateBook(updated);
      BookCover.invalidate(id);
      await app.refresh();
      if (!mounted) return;
      final fresh = app.bookById(id);
      setState(() => _book = fresh ?? updated);
      app.showToast('Cover generated');
    } catch (error) {
      app.showToast('Could not generate the cover: $error');
    }
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
    final palette = context.palette;
    return Scaffold(
      backgroundColor: palette.background,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(palette),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  VellumSpace.xl,
                  VellumSpace.xs,
                  VellumSpace.xl,
                  VellumSpace.xxl,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 680;
                        final cover = _cover(palette);
                        final info = _identity(palette);
                        if (!wide) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Center(child: cover),
                              const SizedBox(height: VellumSpace.lg),
                              info,
                              const SizedBox(height: VellumSpace.xl),
                              _description(palette),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                cover,
                                const SizedBox(width: 40),
                                Expanded(child: info),
                              ],
                            ),
                            const SizedBox(height: VellumSpace.xl),
                            _description(palette),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(VellumPalette palette) {
    return SizedBox(
      height: 58,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VellumSpace.md),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back, size: 19),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 4),
            Text('Library', style: VellumType.ui(12.5, color: palette.textDim)),
            const Spacer(),
            if (_book.hidden)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _status('Hidden', palette),
              ),
          ],
        ),
      ),
    );
  }

  Widget _status(String label, VellumPalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.surfaceHigh,
        borderRadius: VellumRadius.smallAll,
        border: Border.all(color: palette.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility_off_outlined, size: 13, color: palette.textDim),
          const SizedBox(width: 5),
          Text(label, style: VellumType.ui(11, color: palette.textDim)),
        ],
      ),
    );
  }

  Widget _cover(VellumPalette palette) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [palette.coverShadow(hovered: false)],
      ),
      child: BookCover(book: _book, width: 236, height: 354, borderRadius: 10),
    );
  }

  Widget _identity(VellumPalette palette) {
    final theme = Theme.of(context);
    final title = _book.title.isEmpty ? 'Untitled' : _book.title;
    final authors = _book.authors.isEmpty
        ? 'Unknown author'
        : _book.authors.join(', ');
    final rating = _book.rating;
    final filledStars = rating.round().clamp(0, 5).toInt();
    final stars = '★' * filledStars + '☆' * (5 - filledStars);
    final ratingText = rating > 0
        ? '$stars  ${rating.toStringAsFixed(1)}'
        : stars;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: VellumType.display(
            38,
            weight: FontWeight.w600,
            height: 1.06,
            letterSpacing: -0.7,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          authors,
          style: VellumType.ui(
            theme.textTheme.bodyLarge?.fontSize ?? 15,
            height: 1.45,
            color: palette.textDim,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          ratingText,
          style: VellumType.ui(
            13,
            height: 1.3,
            color: palette.accentSoft,
          ).copyWith(letterSpacing: 0.8),
        ),
        if (_book.tags.isNotEmpty) ...[
          const SizedBox(height: VellumSpace.md),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in _book.tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surfaceHigh,
                    borderRadius: VellumRadius.smallAll,
                    border: Border.all(color: palette.line),
                  ),
                  child: Text(
                    tag,
                    style: VellumType.ui(
                      11,
                      weight: FontWeight.w500,
                      color: palette.textDim,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: VellumSpace.lg),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_canRead)
              FilledButton.icon(
                onPressed: _openReader,
                icon: const Icon(Icons.menu_book_outlined, size: 17),
                label: const Text('Read'),
              ),
            _canRead
                ? OutlinedButton(
                    onPressed: _fetchMetadata,
                    child: const Text('Fetch Metadata'),
                  )
                : FilledButton(
                    onPressed: _fetchMetadata,
                    child: const Text('Fetch Metadata'),
                  ),
            OutlinedButton(
              onPressed: _generateCover,
              child: const Text('Generate Cover'),
            ),
            OutlinedButton(
              onPressed: _toggleHidden,
              child: Text(_book.hidden ? 'Unhide Book' : 'Hide Book'),
            ),
          ],
        ),
        _facts(palette),
      ],
    );
  }

  Widget _facts(VellumPalette palette) {
    final progress = _book.progress.clamp(0.0, 1.0).toDouble();
    final percent = (progress * 100).round().clamp(1, 100);
    final rows = <(String, String)>[
      ('Publisher', _book.publisher),
      ('Published', _book.pubdate),
      ('Language', _book.language),
      ('ISBN', _book.isbn),
      ('Format', _book.formats.join(', ').toUpperCase()),
      if (progress > 0)
        ('Progress', progress >= 1 ? 'Finished' : '$percent%'),
    ].where((row) => row.$2.isNotEmpty).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: VellumSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: palette.line),
          const SizedBox(height: VellumSpace.md),
          Wrap(
            spacing: VellumSpace.lg,
            runSpacing: VellumSpace.md,
            children: [
              for (final (label, value) in rows)
                SizedBox(
                  width: 120,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: VellumType.ui(
                          10.5,
                          weight: FontWeight.w500,
                          height: 1.2,
                          color: palette.textDim,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: VellumType.ui(
                          12.5,
                          height: 1.4,
                          color: palette.text,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _description(VellumPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Description',
          style: VellumType.display(
            20,
            weight: FontWeight.w600,
            height: 1.2,
            color: palette.text,
          ),
        ),
        const SizedBox(height: VellumSpace.sm),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: SelectableText(
            _book.description.isEmpty
                ? 'No description available.'
                : _book.description,
            style: VellumType.ui(
              14,
              height: 1.7,
              color: _book.description.isEmpty ? palette.textDim : palette.text,
            ),
          ),
        ),
      ],
    );
  }
}

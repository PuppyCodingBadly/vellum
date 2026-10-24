/// Book cover images and grid cards.
///
/// Ports the cover rendering of `vellum/ui/library_view.py`: cached
/// thumbnails, an initials placeholder and the 160×240 caption card.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/covers.dart';
import '../../core/models.dart';

/// A book cover at [width]×[height], falling back to an initials placeholder.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.width = 160,
    this.height = 240,
    this.borderRadius = 8,
  });

  final Book book;
  final double width;
  final double height;
  final double borderRadius;

  /// Resolved thumbnail paths, keyed by `id:coverPath`.
  ///
  /// The cache is deliberately time-agnostic: the freshness check and the
  /// PNG transcode both run in a background isolate, so `build()` performs no
  /// file I/O. Changed metadata produces a new key (the path changes).
  static final Map<String, Future<String>> _thumbCache =
      <String, Future<String>>{};

  /// Maximum retained thumbnails before the oldest entries are evicted.
  static const int _thumbCacheLimit = 500;

  static void _trimCache() {
    while (_thumbCache.length >= _thumbCacheLimit) {
      _thumbCache.remove(_thumbCache.keys.first);
    }
  }

  static Future<String> _thumbnailFor(
    String dataDir,
    int bookId,
    String coverPath,
  ) {
    if (coverPath.isEmpty) return Future<String>.value('');
    final key = '$bookId:$coverPath';
    final cached = _thumbCache.remove(key);
    if (cached != null) {
      _thumbCache[key] = cached; // refresh recency
      return cached;
    }
    _trimCache();
    final future = Isolate.run(
      () => thumbPath(dataDir, bookId, coverPath),
      debugName: 'cover-thumb-$bookId',
    );
    _thumbCache[key] = future;
    return future;
  }

  /// Drops cached thumbnails for [bookId] (for example after a cover update).
  static void invalidate(int bookId) {
    _thumbCache.removeWhere((key, _) => key.startsWith('$bookId:'));
  }

  String get _initials {
    final words = book.title
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(2);
    final letters = [
      for (final word in words) word.characters.first.toUpperCase(),
    ].join();
    return letters.isEmpty ? '?' : letters;
  }

  Widget _placeholder(Color accent) {
    return ColoredBox(
      color: accent,
      child: Center(
        child: Text(
          _initials,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: width / 5,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    final bookId = book.id ?? 0;
    final future = _thumbnailFor(state.dataDir, bookId, book.coverPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: FutureBuilder<String>(
          future: future,
          builder: (context, snapshot) {
            final path = snapshot.data ?? '';
            if (path.isEmpty) return _placeholder(state.accentColor);
            return Image.file(
              File(path),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Thumbs are at most 320×480; never decode above display size.
              cacheWidth:
                  (width * MediaQuery.devicePixelRatioOf(context)).round(),
              errorBuilder: (context, error, stackTrace) =>
                  _placeholder(state.accentColor),
            );
          },
        ),
      ),
    );
  }
}

/// A library-grid card: cover, caption overlay and tooltip.
class BookCard extends StatelessWidget {
  const BookCard({
    super.key,
    required this.book,
    this.onTap,
    this.onLongPress,
  });

  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  static String _ellipsize(String text, int max) {
    final characters = text.characters;
    if (characters.length <= max) return text;
    return '${characters.take(max - 1).join()}…';
  }

  @override
  Widget build(BuildContext context) {
    final rawTitle = book.title.trim();
    final fullTitle = rawTitle.isEmpty ? 'Untitled' : rawTitle;
    final authors =
        book.authors.isEmpty ? 'Unknown author' : book.authors.join(', ');
    final displayTitle = _ellipsize(fullTitle, 22);
    final displayAuthors = _ellipsize(authors, 24);

    return Tooltip(
      message: '$fullTitle\n$authors',
      child: Opacity(
        opacity: book.hidden ? 0.55 : 1.0,
        child: SizedBox(
          width: 160,
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                BookCover(book: book),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0xD1000000)],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 2),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          displayAuthors,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: onTap,
                    onLongPress: onLongPress,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

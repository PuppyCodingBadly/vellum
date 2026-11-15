/// Book covers and the library's book tile.
///
/// The cover is the object that carries colour; the tile under it is quiet
/// chrome. Thumbnails are still cached and produced off the UI isolate.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../core/covers.dart';
import '../../core/models.dart';
import '../theme.dart';

/// A book cover at [width]×[height], falling back to a cloth-and-initials
/// placeholder when the artwork is missing.
///
/// [fill] makes the cover take the size of its parent, which is what the
/// library grid does; the default 160×240 box remains for details and tests.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.width = 160,
    this.height = 240,
    this.borderRadius = 8,
    this.fill = false,
  });

  final Book book;
  final double width;
  final double height;
  final double borderRadius;
  final bool fill;

  /// Resolved thumbnail paths, keyed by `id:coverPath`.
  ///
  /// The cache is time-agnostic: freshness and the PNG transcode both run in a
  /// background isolate, so `build()` performs no file I/O. Changed metadata
  /// produces a new key (the path changes).
  static final Map<String, Future<String>> _thumbCache =
      <String, Future<String>>{};

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

  Widget _placeholder(BuildContext context, double w, double h) {
    final palette = context.palette;
    final edge = w * 0.12;
    final initialSize = (w / 4.6).clamp(22.0, 58.0).toDouble();
    return ColoredBox(
      color: palette.placeholderInk,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Two hairlines read as a cloth binding without drawing a second
          // object on top of the cover.
          Positioned(
            top: h * 0.075,
            left: edge,
            right: edge,
            child: Container(
              height: 1,
              color: palette.placeholderText.withValues(alpha: 0.22),
            ),
          ),
          Positioned(
            bottom: h * 0.075,
            left: edge,
            right: edge,
            child: Container(
              height: 1,
              color: palette.placeholderText.withValues(alpha: 0.16),
            ),
          ),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: w * 0.12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _initials,
                  textAlign: TextAlign.center,
                  style: VellumType.display(
                    initialSize,
                    weight: FontWeight.w500,
                    height: 1,
                    color: palette.placeholderText,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.of(context);
    final bookId = book.id ?? 0;
    final future = _thumbnailFor(state.dataDir, bookId, book.coverPath);
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget content(double w, double h) {
      return FutureBuilder<String>(
        future: future,
        builder: (context, snapshot) {
          final path = snapshot.data ?? '';
          if (path.isEmpty) return _placeholder(context, w, h);
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            alignment: Alignment.center,
            gaplessPlayback: true,
            // Thumbs are at most 320×480; never decode above display size.
            cacheWidth: w.isFinite && w > 0 ? (w * dpr).round() : null,
            errorBuilder: (context, error, stackTrace) =>
                _placeholder(context, w, h),
          );
        },
      );
    }

    if (fill) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : width;
            final h = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : height;
            return content(w, h);
          },
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: content(width, height),
      ),
    );
  }
}

/// A library tile: cover, title and author beneath it.
///
/// Hover and keyboard focus draw the same lift and ring, so the pointer and
/// the keyboard read as one gesture. The caption sits outside the artwork,
/// which keeps every cover uncropped and readable.
class BookCard extends StatefulWidget {
  const BookCard({super.key, required this.book, this.onTap, this.onLongPress});

  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<BookCard> createState() => _BookCardState();
}

class _BookCardState extends State<BookCard> {
  static const Duration _motion = Duration(milliseconds: 150);
  static const Curve _curve = Curves.easeOutCubic;

  bool _hovered = false;
  bool _focused = false;

  bool get _highlighted => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final book = widget.book;
    final rawTitle = book.title.trim();
    final fullTitle = rawTitle.isEmpty ? 'Untitled' : rawTitle;
    final authors = book.authors.isEmpty
        ? 'Unknown author'
        : book.authors.join(', ');
    final hidden = book.hidden;

    return Semantics(
      button: true,
      label: '$fullTitle, by $authors${hidden ? ', hidden' : ''}',
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        mouseCursor: SystemMouseCursors.click,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Tooltip(
              message: '$fullTitle\n$authors',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: 2 / 3,
                    child: RepaintBoundary(
                      child: AnimatedContainer(
                        duration: _motion,
                        curve: _curve,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: _highlighted
                              ? [palette.coverShadow(hovered: true)]
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AnimatedOpacity(
                                duration: _motion,
                                opacity: hidden ? 0.5 : 1,
                                child: BookCover(
                                  book: book,
                                  borderRadius: 0,
                                  fill: true,
                                ),
                              ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: AnimatedContainer(
                                    duration: _motion,
                                    curve: _curve,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _focused
                                            ? palette.accent
                                            : palette.line.withValues(
                                                alpha: hidden ? 0.5 : 1,
                                              ),
                                        width: _focused ? 2 : 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (hidden)
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: palette.surface.withValues(
                                        alpha: 0.92,
                                      ),
                                      borderRadius: VellumRadius.smallAll,
                                      border: Border.all(color: palette.line),
                                    ),
                                    child: Icon(
                                      Icons.visibility_off_outlined,
                                      size: 13,
                                      color: palette.textDim,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 35,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        fullTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: VellumType.display(
                          14,
                          weight: FontWeight.w500,
                          height: 1.24,
                          color: palette.text,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    authors,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VellumType.ui(
                      11.5,
                      height: 1.35,
                      color: palette.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

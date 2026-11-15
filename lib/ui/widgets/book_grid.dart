/// The shared cover wall used by the library and by shelves.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme.dart';
import 'book_cover.dart';

/// A cover-forward grid of [BookCard]s.
///
/// The tile's main-axis extent is computed from the actual column width:
/// cover (2:3) plus the two-line caption. That keeps the caption inside the
/// tile at every window size instead of letting the grid's aspect ratio guess.
class BookGrid extends StatelessWidget {
  const BookGrid({
    super.key,
    required this.books,
    this.onTap,
    this.onLongPress,
    this.padding = const EdgeInsets.fromLTRB(
      VellumSpace.xl,
      VellumSpace.xs,
      VellumSpace.xl,
      VellumSpace.xl,
    ),
  });

  final List<Book> books;
  final void Function(Book book)? onTap;
  final void Function(Book book, BuildContext cardContext)? onLongPress;
  final EdgeInsets padding;

  static const double _maxTileWidth = 182;
  static const double _gap = 22;
  static const double _captionHeight = 64;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final extent = math.max(
            0.0,
            constraints.maxWidth - padding.horizontal,
          );
          final count = math.max(
            2,
            (extent / (_maxTileWidth + _gap)).ceil(),
          );
          final tileWidth = math.max(
            80.0,
            (extent - _gap * (count - 1)) / count,
          );
          final tileHeight = tileWidth * 1.5 + _captionHeight;
          return GridView.builder(
            padding: padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisExtent: tileHeight,
              mainAxisSpacing: 28,
              crossAxisSpacing: _gap,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              return Builder(
                builder: (cardContext) => BookCard(
                  book: book,
                  onTap: onTap == null ? null : () => onTap!(book),
                  onLongPress: onLongPress == null
                      ? null
                      : () => onLongPress!(book, cardContext),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

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
/// cover (2:3) plus the caption extent [BookCard] reports for the current text
/// scale. That keeps the caption inside the tile at every window size and
/// every text scale instead of letting the grid guess.
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

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    return Scrollbar(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final extent = math.max(
            0.0,
            constraints.maxWidth - padding.horizontal,
          );
          final count = math.max(2, (extent / (_maxTileWidth + _gap)).ceil());
          final tileWidth = math.max(
            80.0,
            (extent - _gap * (count - 1)) / count,
          );
          final tileHeight =
              tileWidth * 1.5 + BookCard.captionExtent(textScaler);
          // The key of each tile is the book it shows; the map lets the sliver
          // match that key to the book's new index, so a reordered grid keeps
          // each tile's hover and focus with its book.
          final indexByKey = <Object, int>{};
          for (var i = 0; i < books.length; i++) {
            indexByKey[books[i].id ?? books[i].path] = i;
          }
          return GridView.builder(
            padding: padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisExtent: tileHeight,
              mainAxisSpacing: 28,
              crossAxisSpacing: _gap,
            ),
            itemCount: books.length,
            findChildIndexCallback: (key) =>
                key is ValueKey<Object> ? indexByKey[key.value] : null,
            itemBuilder: (context, index) {
              final book = books[index];
              return Builder(
                // Identity, not the slot: hover and focus belong to the book,
                // so they follow it across a reorder or a shrink instead of
                // landing on whichever book takes over the reused element.
                key: ValueKey<Object>(book.id ?? book.path),
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

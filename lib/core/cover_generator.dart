/// Renders a typographic cover from a book's metadata.
///
/// Calibre's "Generate cover" builds artwork from the catalogue record; Vellum
/// does the same with the bundled faces and the app's own palette families.
/// The output is a plain 2:3 PNG, so the existing thumbnail cache, details
/// page and reader see it as any other cover file.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Generated covers are 2:3 at 1200×1800 — enough for a 2× details preview
/// and any grid tile without a second render.
const int kGeneratedCoverWidth = 1200;
const int kGeneratedCoverHeight = 1800;

/// The type and colour treatment of a generated cover.
enum CoverStyle {
  paper('Paper'),
  ink('Ink'),
  accent('Accent'),
  cloth('Cloth');

  const CoverStyle(this.label);

  final String label;
}

class _CoverPalette {
  const _CoverPalette({
    required this.background,
    required this.ink,
    required this.dim,
    required this.accent,
  });

  final ui.Color background;
  final ui.Color ink;
  final ui.Color dim;
  final ui.Color accent;
}

const Map<CoverStyle, _CoverPalette> _palettes = <CoverStyle, _CoverPalette>{
  CoverStyle.paper: _CoverPalette(
    background: ui.Color(0xFFF6F2EA),
    ink: ui.Color(0xFF231F1A),
    dim: ui.Color(0xFF6B6357),
    accent: ui.Color(0xFFB87433),
  ),
  CoverStyle.ink: _CoverPalette(
    background: ui.Color(0xFF14120F),
    ink: ui.Color(0xFFEFE8DC),
    dim: ui.Color(0xFFA79D8F),
    accent: ui.Color(0xFFC88A4B),
  ),
  CoverStyle.accent: _CoverPalette(
    background: ui.Color(0xFFB87433),
    ink: ui.Color(0xFFFFF8EE),
    dim: ui.Color(0xFFF0DCC2),
    accent: ui.Color(0xFF2F2A24),
  ),
  CoverStyle.cloth: _CoverPalette(
    background: ui.Color(0xFF2E3A3C),
    ink: ui.Color(0xFFF2E8D8),
    dim: ui.Color(0xFFB9C2BC),
    accent: ui.Color(0xFFD9A55C),
  ),
};

/// Path for a cover generated for [bookId]; distinct from downloaded covers
/// (`<id>.jpg`) so regenerating never overwrites fetched artwork.
String generatedCoverPath(String dataDir, int bookId) =>
    '$dataDir/covers/generated-$bookId.png';

/// Writes [png] to [generatedCoverPath], returning the absolute path.
Future<String> writeGeneratedCover({
  required String dataDir,
  required int bookId,
  required Uint8List png,
}) async {
  final file = File(generatedCoverPath(dataDir, bookId));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png, flush: true);
  return file.path;
}

/// Renders a cover for [title] and [author] in [style].
///
/// Runs on the calling isolate: one 1200×1800 raster takes a few milliseconds,
/// and doing it on the UI isolate keeps the bundled fonts and text layout in
/// one place.
Future<Uint8List> generateCoverPng({
  required String title,
  String author = '',
  String publisher = '',
  CoverStyle style = CoverStyle.paper,
  int width = kGeneratedCoverWidth,
  int height = kGeneratedCoverHeight,
}) async {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('cover size must be positive');
  }
  final palette = _palettes[style]!;
  final w = width.toDouble();
  final h = height.toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w, h),
    ui.Paint()..color = palette.background,
  );

  // A hairline frame is the whole ornament: it reads as a bound cover rather
  // than a screenshot with text on it.
  final inset = w * 0.07;
  canvas.drawRect(
    ui.Rect.fromLTWH(inset, inset, w - inset * 2, h - inset * 2),
    ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = w * 0.003
      ..color = palette.dim.withValues(alpha: 0.55),
  );

  final textLeft = inset * 1.6;
  final textWidth = w - textLeft * 2;
  // The title block is centred between the top margin and the author band, so
  // short and long titles sit on the same optical middle line.
  final titleAreaTop = h * 0.16;
  final titleAreaBottom = h * 0.6;
  final titleHeight = titleAreaBottom - titleAreaTop;

  final cleanTitle = title.trim().isEmpty ? 'Untitled' : title.trim();
  final titlePainter = _fitText(
    build: (size) => _paragraph(
      cleanTitle,
      TextStyle(
        fontFamily: 'Newsreader',
        fontSize: size,
        height: 1.14,
        fontWeight: ui.FontWeight.w500,
        color: palette.ink,
        letterSpacing: size * 0.004,
      ),
      width: textWidth,
      maxLines: 5,
    ),
    maxHeight: titleHeight,
    maxSize: w * 0.115,
    minSize: w * 0.038,
  );
  titlePainter.paint(
    canvas,
    ui.Offset(
      textLeft + (textWidth - titlePainter.width) / 2,
      titleAreaTop + (titleHeight - titlePainter.height) / 2,
    ),
  );

  // The accent rule and author occupy a fixed band, the way a printed jacket
  // puts the byline at the same height whatever the title does.
  final ruleY = h * 0.67;
  final ruleWidth = w * 0.1;
  canvas.drawRect(
    ui.Rect.fromLTWH((w - ruleWidth) / 2, ruleY, ruleWidth, h * 0.003),
    ui.Paint()..color = palette.accent,
  );

  final cleanAuthor = author.trim();
  if (cleanAuthor.isNotEmpty) {
    final authorPainter = _paragraph(
      cleanAuthor.toUpperCase(),
      TextStyle(
        fontFamily: 'InstrumentSans',
        fontSize: w * 0.022,
        height: 1.3,
        fontWeight: ui.FontWeight.w600,
        color: palette.dim,
        letterSpacing: w * 0.004,
      ),
      width: textWidth,
      maxLines: 2,
    );
    authorPainter.paint(
      canvas,
      ui.Offset(
        textLeft + (textWidth - authorPainter.width) / 2,
        ruleY + h * 0.03,
      ),
    );
    authorPainter.dispose();
  }

  final cleanPublisher = publisher.trim();
  if (cleanPublisher.isNotEmpty) {
    final publisherPainter = _paragraph(
      cleanPublisher.toUpperCase(),
      TextStyle(
        fontFamily: 'InstrumentSans',
        fontSize: w * 0.016,
        height: 1.3,
        color: palette.dim.withValues(alpha: 0.8),
        letterSpacing: w * 0.003,
      ),
      width: textWidth,
      maxLines: 1,
    );
    publisherPainter.paint(
      canvas,
      ui.Offset(
        (w - publisherPainter.width) / 2,
        h - inset - h * 0.05 - publisherPainter.height,
      ),
    );
    publisherPainter.dispose();
  }

  titlePainter.dispose();

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('cover renderer produced no PNG data');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

TextPainter _paragraph(
  String text,
  TextStyle style, {
  required double width,
  required int maxLines,
}) {
  return TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: ui.TextAlign.center,
    textDirection: ui.TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: width);
}

/// Largest font size whose laid-out height still fits [maxHeight].
TextPainter _fitText({
  required TextPainter Function(double size) build,
  required double maxHeight,
  required double maxSize,
  required double minSize,
}) {
  var low = minSize;
  var high = maxSize;
  var best = build(minSize);
  for (var step = 0; step < 14; step++) {
    final size = (low + high) / 2;
    final painter = build(size);
    if (painter.height <= maxHeight) {
      low = size;
      best.dispose();
      best = painter;
    } else {
      high = size;
      painter.dispose();
    }
    if (high - low < 0.5) break;
  }
  return best;
}

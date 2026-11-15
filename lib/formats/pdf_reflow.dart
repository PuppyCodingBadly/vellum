/// Layout analysis and word-sprite atlases for PDF reflow.
///
/// The page is never OCR'd. PDFium's text layer supplies a box, a baseline,
/// and a font size for every character; this file groups those into words,
/// lines, and paragraphs, then crops the original glyphs out of the raster as
/// tintable sprites. The reader wraps those sprites to the window width, so
/// the original type and symbols survive while the line breaks do not.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One character from PDFium's text layer, in PDF user-space points.
class PdfChar {
  const PdfChar({
    required this.text,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
    required this.baseline,
    required this.fontSize,
  });

  final String text;
  final double left;
  final double bottom;
  final double right;
  final double top;

  /// Baseline origin reported by `FPDFText_GetCharOrigin`.
  final double baseline;
  final double fontSize;

  bool get isWhitespace => text.trim().isEmpty;
}

/// A raster image or chart crop found on the page.
class PdfImagePlacement {
  const PdfImagePlacement({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final double left;
  final double bottom;
  final double right;
  final double top;
}

/// The layout kind of a reflowed paragraph.
enum PdfReflowTextKind { body, heading, quote, list }

/// A reflowed PDF page: tintable word sprites plus image/chart blocks.
class PdfReflowPage {
  const PdfReflowPage({
    required this.atlasPng,
    required this.blocks,
    required this.pageWidth,
    required this.pageHeight,
    required this.medianFontSize,
    required this.bodyWidth,
    required this.hasText,
    this.message,
  });

  /// A page with no usable text layer. The reader falls back to the page
  /// bitmap rather than inventing text with OCR.
  factory PdfReflowPage.fallback(
    String message, {
    required double pageWidth,
    required double pageHeight,
  }) => PdfReflowPage(
    atlasPng: null,
    blocks: const <PdfReflowBlock>[],
    pageWidth: pageWidth,
    pageHeight: pageHeight,
    medianFontSize: 12,
    bodyWidth: pageWidth,
    hasText: false,
    message: message,
  );

  /// A single RGBA atlas of white glyph masks, tinted at paint time.
  final Uint8List? atlasPng;

  final List<PdfReflowBlock> blocks;
  final double pageWidth;
  final double pageHeight;
  final double medianFontSize;

  /// Approximate width of the text column in PDF points; used to scale images.
  final double bodyWidth;

  final bool hasText;

  /// Why reflow could not run (no text layer, rotated page, dense page).
  final String? message;
}

/// One block in reading order.
sealed class PdfReflowBlock {
  const PdfReflowBlock();

  /// Top edge in PDF user-space points (higher is earlier on the page).
  double get top;
}

/// A paragraph made of lines, each made of word sprites.
class PdfReflowParagraph extends PdfReflowBlock {
  const PdfReflowParagraph({
    required this.lines,
    required this.kind,
    required this.indentPoints,
    required this.top,
  });

  final List<PdfReflowLine> lines;
  final PdfReflowTextKind kind;
  final double indentPoints;

  @override
  final double top;

  /// The recognized text, used for semantics and a copy action.
  String get text => lines
      .map((line) => line.words.map((word) => word.text).join(' '))
      .join(' ');
}

/// One original line box; reflowing discards these break positions but keeps
/// the line height so mixed font sizes stay ordered.
class PdfReflowLine {
  const PdfReflowLine({
    required this.words,
    required this.fontSize,
    required this.heightPoints,
  });

  final List<PdfReflowWord> words;
  final double fontSize;
  final double heightPoints;
}

/// One word cropped from the page raster.
class PdfReflowWord {
  const PdfReflowWord({
    required this.text,
    required this.atlasX,
    required this.atlasY,
    required this.atlasWidth,
    required this.atlasHeight,
    required this.widthPoints,
    required this.heightPoints,
  });

  final String text;
  final int atlasX;
  final int atlasY;
  final int atlasWidth;
  final int atlasHeight;

  /// Display size is computed from these points and the reader's font size.
  final double widthPoints;
  final double heightPoints;
}

/// An image or chart crop, placed at its original vertical position.
class PdfReflowImageBlock extends PdfReflowBlock {
  const PdfReflowImageBlock({
    required this.png,
    required this.widthPoints,
    required this.heightPoints,
    required this.top,
  });

  final Uint8List png;
  final double widthPoints;
  final double heightPoints;

  @override
  final double top;
}

/// Build a reflow page from PDFium text boxes and a rendered page bitmap.
///
/// [renderScale] is the bitmap's pixels per PDF point. [bitmap] must be the
/// same page at that scale; word crops are taken from it.
PdfReflowPage buildPdfReflowPage({
  required List<PdfChar> chars,
  required List<PdfImagePlacement> images,
  required img.Image bitmap,
  required double renderScale,
  required double pageWidth,
  required double pageHeight,
}) {
  final glyphs = chars.where((char) => !char.isWhitespace).toList();
  if (glyphs.length < 6) {
    return PdfReflowPage.fallback(
      'This page has no text layer; showing the page image.',
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );
  }
  if (renderScale <= 0 ||
      !renderScale.isFinite ||
      pageWidth <= 0 ||
      pageHeight <= 0) {
    return PdfReflowPage.fallback(
      'This page could not be reflowed.',
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );
  }

  final sizes = glyphs
      .map((char) => char.fontSize)
      .where((size) => size > 0 && size.isFinite)
      .toList()
    ..sort();
  final medianFontSize = sizes.isEmpty
      ? 12.0
      : sizes[sizes.length ~/ 2].clamp(5.0, 72.0).toDouble();

  final words = _groupWords(chars);
  if (words.isEmpty) {
    return PdfReflowPage.fallback(
      'This page has no text layer; showing the page image.',
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );
  }

  var lines = _groupLines(words);
  lines = _readingOrder(lines, pageWidth);
  lines = lines.where((line) {
    // Page numbers and running heads live in the margins and are short.
    final width = line.right - line.left;
    final inTop = line.top > pageHeight * 0.955;
    final inBottom = line.bottom < pageHeight * 0.045;
    return !(inTop || inBottom) || width > pageWidth * 0.55;
  }).toList();
  if (lines.isEmpty) {
    return PdfReflowPage.fallback(
      'Only page furniture was found; showing the page image.',
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );
  }

  final bodyLeft = lines.map((line) => line.left).reduce(math.min);
  final bodyRight = lines.map((line) => line.right).reduce(math.max);
  final bodyWidth = math.max(1.0, bodyRight - bodyLeft);
  final paragraphDrafts = _groupParagraphs(
    lines,
    medianFontSize: medianFontSize,
    pageWidth: pageWidth,
    bodyLeft: bodyLeft,
    bodyWidth: bodyWidth,
  );

  final lineByWord = <_WordDraft, _LineDraft>{};
  for (final line in lines) {
    for (final word in line.words) {
      lineByWord[word] = line;
    }
  }
  final atlas = _buildAtlas(
    words: words,
    lineByWord: lineByWord,
    bitmap: bitmap,
    renderScale: renderScale,
    pageHeight: pageHeight,
  );
  if (atlas == null) {
    return PdfReflowPage.fallback(
      'This page is too dense to reflow; showing the page image.',
      pageWidth: pageWidth,
      pageHeight: pageHeight,
    );
  }

  final blocks = <PdfReflowBlock>[
    for (final draft in paragraphDrafts) _paragraph(draft, atlas.sprites),
  ];
  for (final image in images) {
    final width = image.right - image.left;
    final height = image.top - image.bottom;
    final area = width * height;
    if (width < 12 ||
        height < 12 ||
        area < pageWidth * pageHeight * 0.012 ||
        area > pageWidth * pageHeight * 0.94) {
      continue;
    }
    final png = _cropPng(
      bitmap,
      left: image.left,
      top: image.top,
      right: image.right,
      bottom: image.bottom,
      pageHeight: pageHeight,
      scale: renderScale,
    );
    if (png == null) continue;
    blocks.add(
      PdfReflowImageBlock(
        png: png,
        widthPoints: width,
        heightPoints: height,
        top: image.top,
      ),
    );
  }
  blocks.sort((a, b) => b.top.compareTo(a.top));

  return PdfReflowPage(
    atlasPng: atlas.png,
    blocks: blocks,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
    medianFontSize: medianFontSize,
    bodyWidth: bodyWidth,
    hasText: true,
  );
}

PdfReflowParagraph _paragraph(
  _ParagraphDraft draft,
  Map<_WordDraft, _Sprite> sprites,
) {
  return PdfReflowParagraph(
    lines: [
      for (final line in draft.lines)
        PdfReflowLine(
          words: [
            for (final word in line.words)
              _spriteWord(word, sprites[word]),
          ],
          fontSize: line.fontSize,
          heightPoints: line.top - line.bottom,
        ),
    ],
    kind: draft.kind,
    indentPoints: draft.indentPoints,
    top: draft.top,
  );
}

PdfReflowWord _spriteWord(_WordDraft word, _Sprite? sprite) {
  if (sprite == null) {
    return PdfReflowWord(
      text: word.text,
      atlasX: 0,
      atlasY: 0,
      atlasWidth: 0,
      atlasHeight: 0,
      widthPoints: 0,
      heightPoints: 0,
    );
  }
  return PdfReflowWord(
    text: word.text,
    atlasX: sprite.x,
    atlasY: sprite.y,
    atlasWidth: sprite.width,
    atlasHeight: sprite.height,
    widthPoints: sprite.widthPoints,
    heightPoints: sprite.heightPoints,
  );
}

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

class _WordDraft {
  _WordDraft(this.chars)
    : text = chars.map((char) => char.text).join(),
      left = chars.map((char) => char.left).reduce(math.min),
      right = chars.map((char) => char.right).reduce(math.max),
      bottom = chars.map((char) => char.bottom).reduce(math.min),
      top = chars.map((char) => char.top).reduce(math.max),
      baseline = chars.first.baseline,
      fontSize = chars.map((char) => char.fontSize).reduce(math.max);

  final List<PdfChar> chars;
  final String text;
  final double left;
  final double right;
  final double bottom;
  final double top;
  final double baseline;
  final double fontSize;
}

class _LineDraft {
  _LineDraft(this.words)
    : left = words.map((word) => word.left).reduce(math.min),
      right = words.map((word) => word.right).reduce(math.max),
      bottom = words.map((word) => word.bottom).reduce(math.min),
      top = words.map((word) => word.top).reduce(math.max),
      fontSize = words.map((word) => word.fontSize).reduce(math.max),
      baseline = words.first.baseline;

  final List<_WordDraft> words;
  final double left;
  final double right;
  final double bottom;
  final double top;
  final double fontSize;
  final double baseline;
}

class _ParagraphDraft {
  const _ParagraphDraft({
    required this.lines,
    required this.kind,
    required this.indentPoints,
    required this.top,
  });

  final List<_LineDraft> lines;
  final PdfReflowTextKind kind;
  final double indentPoints;
  final double top;
}

List<_WordDraft> _groupWords(List<PdfChar> chars) {
  final words = <_WordDraft>[];
  var current = <PdfChar>[];
  void close() {
    if (current.isNotEmpty) {
      words.add(_WordDraft(List<PdfChar>.of(current)));
      current = <PdfChar>[];
    }
  }

  for (final char in chars) {
    if (char.isWhitespace) {
      close();
      continue;
    }
    // Scripts that do not put spaces between words still need line-break
    // opportunities. Give each wide character its own sprite.
    final code = char.text.codeUnitAt(0);
    if (_isWideCharacter(code)) {
      close();
      words.add(_WordDraft(<PdfChar>[char]));
      continue;
    }
    if (current.isEmpty) {
      current.add(char);
      continue;
    }
    final previous = current.last;
    final gap = char.left - previous.right;
    final baselineGap = (char.baseline - previous.baseline).abs();
    final size = math.max(previous.fontSize, char.fontSize);
    if (gap > math.max(1.0, size * 0.5) ||
        baselineGap > math.max(1.0, size * 0.6)) {
      close();
    }
    current.add(char);
  }
  close();
  return words;
}

bool _isWideCharacter(int code) =>
    (code >= 0x3040 && code <= 0x30FF) || // Hiragana/Katakana
    (code >= 0x3400 && code <= 0x4DBF) || // CJK Extension A
    (code >= 0x4E00 && code <= 0x9FFF) || // CJK Unified
    (code >= 0xAC00 && code <= 0xD7AF) || // Hangul
    (code >= 0xF900 && code <= 0xFAFF) || // CJK Compatibility
    (code >= 0x20000 && code <= 0x2FA1F); // CJK Extensions B–F

List<_LineDraft> _groupLines(List<_WordDraft> words) {
  final lines = <_LineDraft>[];
  var current = <_WordDraft>[];
  void close() {
    if (current.isNotEmpty) {
      lines.add(_LineDraft(List<_WordDraft>.of(current)));
      current = <_WordDraft>[];
    }
  }

  for (final word in words) {
    if (current.isEmpty) {
      current.add(word);
      continue;
    }
    final line = _LineDraft(current);
    final baselineGap = (word.baseline - line.baseline).abs();
    final horizontalGap = word.left - line.right;
    final tolerance = math.max(1.5, line.fontSize * 0.35);
    if (baselineGap > tolerance ||
        horizontalGap > math.max(8.0, line.fontSize * 2.2)) {
      close();
    }
    current.add(word);
  }
  close();
  return lines;
}

/// Put lines into reading order, including a basic two-column split.
List<_LineDraft> _readingOrder(List<_LineDraft> lines, double pageWidth) {
  int compare(_LineDraft a, _LineDraft b) {
    final byTop = b.top.compareTo(a.top);
    if (byTop != 0) return byTop;
    return a.left.compareTo(b.left);
  }

  final centre = pageWidth / 2;
  final left = <_LineDraft>[];
  final right = <_LineDraft>[];
  final spanning = <_LineDraft>[];
  for (final line in lines) {
    if (line.right <= centre + pageWidth * 0.02) {
      left.add(line);
    } else if (line.left >= centre - pageWidth * 0.02) {
      right.add(line);
    } else {
      spanning.add(line);
    }
  }
  if (left.length >= 3 && right.length >= 3) {
    left.sort(compare);
    right.sort(compare);
    spanning.sort(compare);
    return <_LineDraft>[...spanning, ...left, ...right];
  }
  lines.sort(compare);
  return lines;
}

List<_ParagraphDraft> _groupParagraphs(
  List<_LineDraft> lines, {
  required double medianFontSize,
  required double pageWidth,
  required double bodyLeft,
  required double bodyWidth,
}) {
  final paragraphs = <_ParagraphDraft>[];
  var current = <_LineDraft>[];

  void close() {
    if (current.isEmpty) return;
    final kind = _classify(current, medianFontSize, bodyLeft);
    final indent = (current.map((line) => line.left).reduce(math.min) -
            bodyLeft)
        .clamp(0.0, bodyWidth)
        .toDouble();
    paragraphs.add(
      _ParagraphDraft(
        lines: List<_LineDraft>.of(current),
        kind: kind,
        indentPoints: indent,
        top: current.map((line) => line.top).reduce(math.max),
      ),
    );
    current = <_LineDraft>[];
  }

  for (final line in lines) {
    if (current.isEmpty) {
      current.add(line);
      continue;
    }
    final previous = current.last;
    final baselineGap = (previous.baseline - line.baseline).abs();
    final gap = previous.bottom - line.top;
    final sizeChange =
        (line.fontSize - previous.fontSize).abs() /
        math.max(1, previous.fontSize);
    final indented = line.left - previous.left > pageWidth * 0.025;
    if (baselineGap > previous.fontSize * 1.8 ||
        gap > previous.fontSize * 0.9 ||
        sizeChange > 0.18 ||
        indented) {
      close();
    }
    current.add(line);
  }
  close();
  return paragraphs;
}

PdfReflowTextKind _classify(
  List<_LineDraft> lines,
  double medianFontSize,
  double bodyLeft,
) {
  final maxSize = lines.map((line) => line.fontSize).reduce(math.max);
  if (maxSize >= medianFontSize * 1.22) return PdfReflowTextKind.heading;
  final indent = lines.map((line) => line.left).reduce(math.min) - bodyLeft;
  if (indent > 10) return PdfReflowTextKind.quote;
  final first = lines.first.words.first.text;
  if (RegExp(r'^([•▪◦‣·]|\(?\d+[.)])').hasMatch(first)) {
    return PdfReflowTextKind.list;
  }
  return PdfReflowTextKind.body;
}

// ---------------------------------------------------------------------------
// Sprite atlas
// ---------------------------------------------------------------------------

class _Sprite {
  const _Sprite({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.widthPoints,
    required this.heightPoints,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final double widthPoints;
  final double heightPoints;
}

class _AtlasResult {
  const _AtlasResult(this.png, this.sprites);

  final Uint8List png;
  final Map<_WordDraft, _Sprite> sprites;
}

class _Crop {
  _Crop({
    required this.word,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
  });

  final _WordDraft word;
  final int x0;
  final int y0;
  final int x1;
  final int y1;

  int get width => x1 - x0;
  int get height => y1 - y0;
}

_AtlasResult? _buildAtlas({
  required List<_WordDraft> words,
  required Map<_WordDraft, _LineDraft> lineByWord,
  required img.Image bitmap,
  required double renderScale,
  required double pageHeight,
}) {
  const padding = 2;
  final crops = <_Crop>[];
  var maxCropWidth = 0;
  for (final word in words) {
    final line = lineByWord[word];
    if (line == null) continue;
    final x0 = ((word.left * renderScale).floor() - padding).clamp(
      0,
      bitmap.width - 1,
    );
    final x1 = ((word.right * renderScale).ceil() + padding).clamp(
      x0 + 1,
      bitmap.width,
    );
    final y0 =
        (((pageHeight - line.top) * renderScale).floor() - padding).clamp(
          0,
          bitmap.height - 1,
        );
    final y1 =
        (((pageHeight - line.bottom) * renderScale).ceil() + padding).clamp(
          y0 + 1,
          bitmap.height,
        );
    if (x1 - x0 < 1 || y1 - y0 < 1) continue;
    crops.add(_Crop(word: word, x0: x0, y0: y0, x1: x1, y1: y1));
    maxCropWidth = math.max(maxCropWidth, x1 - x0);
  }
  if (crops.isEmpty) return null;

  final atlasWidth = math.min(4096, math.max(256, maxCropWidth + padding));
  var cursorX = 0;
  var cursorY = 0;
  var rowHeight = 0;
  final placed = <_Crop>[];
  final positions = <_Crop, (int, int)>{};
  for (final crop in crops) {
    if (cursorX + crop.width > atlasWidth) {
      cursorX = 0;
      cursorY += rowHeight + padding;
      rowHeight = 0;
    }
    positions[crop] = (cursorX, cursorY);
    placed.add(crop);
    cursorX += crop.width + padding;
    rowHeight = math.max(rowHeight, crop.height);
  }
  final atlasHeight = cursorY + rowHeight + padding;
  if (atlasHeight <= 0 || atlasHeight > 8192) return null;

  final atlas = img.Image(
    width: atlasWidth,
    height: atlasHeight,
    numChannels: 4,
  );
  final sprites = <_WordDraft, _Sprite>{};
  for (final crop in placed) {
    final position = positions[crop]!;
    final mask = _wordMask(bitmap, crop.x0, crop.y0, crop.width, crop.height);
    if (mask == null) continue;
    img.compositeImage(atlas, mask, dstX: position.$1, dstY: position.$2);
    sprites[crop.word] = _Sprite(
      x: position.$1,
      y: position.$2,
      width: crop.width,
      height: crop.height,
      widthPoints: crop.width / renderScale,
      heightPoints: crop.height / renderScale,
    );
  }
  if (sprites.isEmpty) return null;
  return _AtlasResult(img.encodePng(atlas), sprites);
}

// ---------------------------------------------------------------------------
// Bitmap helpers
// ---------------------------------------------------------------------------

img.Image? _wordMask(
  img.Image page,
  int x,
  int y,
  int width,
  int height,
) {
  if (width <= 0 || height <= 0) return null;
  final mask = img.Image(width: width, height: height, numChannels: 4);
  var opaque = false;
  for (var py = 0; py < height; py++) {
    final sy = y + py;
    if (sy < 0 || sy >= page.height) continue;
    for (var px = 0; px < width; px++) {
      final sx = x + px;
      if (sx < 0 || sx >= page.width) continue;
      final pixel = page.getPixel(sx, sy);
      final luminance =
          0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b;
      final alpha = (255 - luminance).clamp(0, 255).toInt();
      if (alpha == 0) continue;
      opaque = true;
      mask.setPixelRgba(px, py, 255, 255, 255, alpha);
    }
  }
  return opaque ? mask : null;
}

Uint8List? _cropPng(
  img.Image page, {
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double pageHeight,
  required double scale,
}) {
  final x0 = (left * scale).floor().clamp(0, page.width - 1);
  final x1 = (right * scale).ceil().clamp(x0 + 1, page.width);
  final y0 = ((pageHeight - top) * scale).floor().clamp(
    0,
    page.height - 1,
  );
  final y1 = ((pageHeight - bottom) * scale).ceil().clamp(y0 + 1, page.height);
  if (x1 - x0 < 2 || y1 - y0 < 2) return null;
  return img.encodePng(
    img.copyCrop(page, x: x0, y: y0, width: x1 - x0, height: y1 - y0),
  );
}

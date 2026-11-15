import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vellum/formats/ocr.dart';
import 'package:vellum/formats/pdf_reflow.dart';

List<PdfChar> _line(
  String text,
  double x,
  double baseline, {
  double fontSize = 12,
}) {
  final chars = <PdfChar>[];
  var cursor = x;
  final height = fontSize * 0.72;
  for (final rune in text.runes) {
    final value = String.fromCharCode(rune);
    final width = value == ' ' ? fontSize * 0.28 : fontSize * 0.55;
    chars.add(
      PdfChar(
        text: value,
        left: cursor,
        right: cursor + width,
        bottom: baseline - height,
        top: baseline + height * 0.25,
        baseline: baseline,
        fontSize: fontSize,
      ),
    );
    cursor += width;
  }
  return chars;
}

/// Paint each character's box onto the page raster, as PDFium's raster does.
void _paintChars(img.Image bitmap, List<PdfChar> chars, img.Color color) {
  for (final char in chars) {
    img.fillRect(
      bitmap,
      x1: char.left.round(),
      y1: (792 - char.top).round(),
      x2: char.right.round(),
      y2: (792 - char.bottom).round(),
      color: color,
    );
  }
}

/// One OCR word in image pixels from the top-left.
OcrWord _ocrWord(
  String text,
  int left,
  int top,
  int width,
  int height, {
  int block = 1,
  int paragraph = 1,
  int line = 1,
}) => OcrWord(
  text: text,
  left: left,
  top: top,
  width: width,
  height: height,
  block: block,
  paragraph: paragraph,
  line: line,
  confidence: 95,
);

/// Paint each OCR word's box as ink on a white page raster.
img.Image _paintWords(
  List<OcrWord> words, {
  required int width,
  required int height,
}) {
  final bitmap = img.Image(width: width, height: height);
  img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
  for (final word in words) {
    img.fillRect(
      bitmap,
      x1: word.left,
      y1: word.top,
      x2: word.right - 1,
      y2: word.bottom - 1,
      color: img.ColorRgb8(20, 20, 20),
    );
  }
  return bitmap;
}

void main() {
  test('groups lines into paragraphs, headings, and indented quotes', () {
    final chars = <PdfChar>[
      ..._line('Chapter One', 72, 700, fontSize: 22),
      ..._line(
        'The first body line wraps across this original page width and',
        72,
        650,
      ),
      ..._line(
        'continues on the next line with more of the same paragraph.',
        72,
        636,
      ),
      ..._line(
        'An indented quotation sits away from the body margin.',
        96,
        600,
      ),
      ..._line('9', 300, 775),
    ];
    final bitmap = img.Image(width: 800, height: 1000);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    for (final char in chars) {
      img.fillRect(
        bitmap,
        x1: (char.left * 1.2).round(),
        y1: ((792 - char.top) * 1.2).round(),
        x2: (char.right * 1.2).round(),
        y2: ((792 - char.bottom) * 1.2).round(),
        color: img.ColorRgb8(20, 20, 20),
      );
    }

    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1.2,
      pageWidth: 612,
      pageHeight: 792,
    );

    expect(page.hasText, isTrue);
    expect(page.usedOcr, isFalse);
    expect(page.atlasPng, isNotNull);
    expect(page.atlasPng!.length, greaterThan(0));
    final paragraphs = page.blocks.whereType<PdfReflowParagraph>().toList();
    expect(paragraphs, hasLength(3));
    expect(paragraphs.first.kind, PdfReflowTextKind.heading);
    expect(paragraphs.first.text, 'Chapter One');
    expect(paragraphs[1].kind, PdfReflowTextKind.body);
    expect(paragraphs[1].text, contains('first body line'));
    expect(paragraphs[1].text, contains('next line'));
    expect(paragraphs[2].kind, PdfReflowTextKind.quote);
    expect(paragraphs[2].indentPoints, greaterThan(10));
    // The short page number in the top margin is page furniture.
    expect(paragraphs.expand((p) => p.text.split(' ')), isNot(contains('9')));
    final firstWord = paragraphs.first.lines.first.words.first;
    expect(firstWord.atlasWidth, greaterThan(0));
    expect(firstWord.widthPoints, greaterThan(0));
  });

  test('a page with no text reports the image fallback', () {
    final bitmap = img.Image(width: 100, height: 100);
    final page = buildPdfReflowPage(
      chars: const <PdfChar>[],
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    expect(page.hasText, isFalse);
    expect(page.atlasPng, isNull);
    expect(page.message, contains('no text layer'));
  });

  test('OCR word boxes reflow with Tesseract line and paragraph ids', () {
    const scale = 2.0;
    final words = <OcrWord>[
      _ocrWord('Chapter', 100, 80, 140, 34),
      _ocrWord('One', 250, 80, 70, 34),
      _ocrWord('The', 100, 200, 40, 24, paragraph: 2),
      _ocrWord('first', 150, 200, 55, 24, paragraph: 2),
      _ocrWord('body', 215, 200, 55, 24, paragraph: 2),
      _ocrWord('line', 280, 200, 40, 24, paragraph: 2),
      _ocrWord('continues', 100, 232, 95, 24, paragraph: 2, line: 2),
      _ocrWord('here', 205, 232, 50, 24, paragraph: 2, line: 2),
      // Tesseract emits the right column after the left, even though both
      // start at the same height.
      _ocrWord('Right', 700, 210, 60, 24, block: 2),
      _ocrWord('column', 770, 210, 75, 24, block: 2),
      _ocrWord('9', 590, 1500, 20, 20, block: 3),
    ];
    final bitmap = _paintWords(words, width: 1224, height: 1584);

    final page = buildPdfReflowPageFromOcr(
      layout: OcrLayout(
        words: words,
        imageWidth: bitmap.width,
        imageHeight: bitmap.height,
      ),
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: scale,
      pageWidth: 612,
      pageHeight: 792,
    );

    expect(page.hasText, isTrue);
    expect(page.usedOcr, isTrue);
    expect(page.atlasPng, isNotNull);
    final paragraphs = page.blocks.whereType<PdfReflowParagraph>().toList();
    expect(paragraphs.map((paragraph) => paragraph.text), [
      'Chapter One',
      'The first body line continues here',
      'Right column',
    ]);
    expect(paragraphs.first.kind, PdfReflowTextKind.heading);
    // The page number sits in the bottom margin and is page furniture.
    expect(paragraphs.expand((p) => p.text.split(' ')), isNot(contains('9')));
    // A second block is a column, not an indent from the page margin.
    expect(paragraphs[2].kind, PdfReflowTextKind.body);
    expect(paragraphs[2].indentPoints, lessThan(10));
    final wordsOut = paragraphs
        .expand((paragraph) => paragraph.lines)
        .expand((line) => line.words)
        .toList();
    expect(wordsOut.every((word) => word.atlasWidth > 0), isTrue);
    expect(wordsOut.every((word) => word.widthPoints > 0), isTrue);
    // Words in a line are separated by spaces when the text is copied.
    expect(paragraphs.first.text, 'Chapter One');
  });

  test('OCR wide-script words copy without spaces', () {
    final words = <OcrWord>[
      _ocrWord('漢', 100, 200, 30, 30),
      _ocrWord('字', 135, 200, 30, 30),
    ];
    final bitmap = _paintWords(words, width: 400, height: 400);
    final page = buildPdfReflowPageFromOcr(
      layout: OcrLayout(
        words: words,
        imageWidth: bitmap.width,
        imageHeight: bitmap.height,
      ),
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 2,
      pageWidth: 200,
      pageHeight: 400,
    );
    expect(page.hasText, isTrue);
    expect(
      page.blocks
          .whereType<PdfReflowParagraph>()
          .map((paragraph) => paragraph.text)
          .join(),
      '漢字',
    );
  });

  test('OCR blocks keep TSV order instead of sorting by top', () {
    const scale = 2.0;
    // Both blocks start at the same height and interleave line by line; the
    // old top-sort reordered them and mixed the columns.
    final words = <OcrWord>[
      _ocrWord('One', 100, 200, 60, 24),
      _ocrWord('two', 100, 232, 60, 24, line: 2),
      _ocrWord('Three', 700, 200, 90, 24, block: 2),
      _ocrWord('four', 700, 232, 70, 24, block: 2, line: 2),
    ];
    final bitmap = _paintWords(words, width: 1224, height: 1584);

    final page = buildPdfReflowPageFromOcr(
      layout: OcrLayout(
        words: words,
        imageWidth: bitmap.width,
        imageHeight: bitmap.height,
      ),
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: scale,
      pageWidth: 612,
      pageHeight: 792,
    );

    expect(page.hasText, isTrue);
    final paragraphs = page.blocks
        .whereType<PdfReflowParagraph>()
        .map((paragraph) => paragraph.text)
        .toList();
    expect(paragraphs, ['One two', 'Three four']);
  });

  test('OCR keeps a separate photo but drops the scanned page image', () {
    const scale = 2.0;
    final words = <OcrWord>[
      _ocrWord('Scanned', 100, 100, 160, 40),
      _ocrWord('words', 270, 100, 100, 40),
    ];
    final bitmap = _paintWords(words, width: 1224, height: 1584);

    final page = buildPdfReflowPageFromOcr(
      layout: OcrLayout(
        words: words,
        imageWidth: bitmap.width,
        imageHeight: bitmap.height,
      ),
      images: const <PdfImagePlacement>[
        // The full-page scan behind the recognized words.
        PdfImagePlacement(left: 0, bottom: 0, right: 612, top: 792),
        // A photo elsewhere on the page, not enclosing the words.
        PdfImagePlacement(left: 400, bottom: 60, right: 550, top: 260),
      ],
      bitmap: bitmap,
      renderScale: scale,
      pageWidth: 612,
      pageHeight: 792,
    );

    expect(page.hasText, isTrue);
    expect(page.usedOcr, isTrue);
    final images = page.blocks.whereType<PdfReflowImageBlock>().toList();
    expect(images, hasLength(1));
    expect(images.single.widthPoints, closeTo(150, 1));
    expect(images.single.heightPoints, closeTo(200, 1));
  });

  test('OCR with no words falls back to the page image', () {
    final bitmap = img.Image(width: 100, height: 100);
    final page = buildPdfReflowPageFromOcr(
      layout: const OcrLayout(
        words: <OcrWord>[],
        imageWidth: 100,
        imageHeight: 100,
      ),
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    expect(page.hasText, isFalse);
    expect(page.message, contains('OCR found no text'));
  });

  test('two-column pages read the left column before the right', () {
    final chars = <PdfChar>[
      ..._line('Left column first line here', 60, 600),
      ..._line('Left column second line here', 60, 586),
      ..._line('Left column third line here', 60, 572),
      ..._line('Right column first line', 330, 600),
      ..._line('Right column second line', 330, 586),
      ..._line('Right column third line', 330, 572),
    ];
    final bitmap = img.Image(width: 900, height: 800);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    for (final char in chars) {
      img.fillRect(
        bitmap,
        x1: char.left.round(),
        y1: (792 - char.top).round(),
        x2: char.right.round(),
        y2: (792 - char.bottom).round(),
        color: img.ColorRgb8(10, 10, 10),
      );
    }
    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    final text = page.blocks
        .whereType<PdfReflowParagraph>()
        .map((p) => p.text)
        .join('\n');
    expect(
      text.indexOf('Left column first'),
      lessThan(text.indexOf('Right column first')),
    );
    // Indent is measured from each column's own margin: the right column is
    // body text, not an indented quotation, just because it starts mid-page.
    final paragraphs = page.blocks.whereType<PdfReflowParagraph>().toList();
    final leftParagraph = paragraphs.firstWhere(
      (p) => p.text.startsWith('Left column'),
    );
    final rightParagraph = paragraphs.firstWhere(
      (p) => p.text.startsWith('Right column'),
    );
    expect(leftParagraph.kind, PdfReflowTextKind.body);
    expect(leftParagraph.indentPoints, closeTo(0, 0.001));
    expect(rightParagraph.kind, PdfReflowTextKind.body);
    expect(rightParagraph.indentPoints, closeTo(0, 0.001));
  });

  test('wide CJK characters become their own breakable words', () {
    final chars = <PdfChar>[
      ..._line('Hello 日本語', 72, 650),
      ..._line('second line of the same paragraph', 72, 636),
    ];
    final bitmap = img.Image(width: 800, height: 800);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    for (final char in chars) {
      img.fillRect(
        bitmap,
        x1: char.left.round(),
        y1: (792 - char.top).round(),
        x2: char.right.round(),
        y2: (792 - char.bottom).round(),
        color: img.ColorRgb8(10, 10, 10),
      );
    }
    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    final words = page.blocks
        .whereType<PdfReflowParagraph>()
        .expand((p) => p.lines)
        .expand((l) => l.words)
        .map((w) => w.text)
        .toList();
    expect(words, containsAllInOrder(<String>['Hello', '日', '本', '語']));
    expect(words, contains('second'));
    final paragraph = page.blocks.whereType<PdfReflowParagraph>().first;
    // Wide-character breaks are not word gaps: copy text stays space-free.
    expect(paragraph.text, startsWith('Hello 日本語'));
    expect(paragraph.text, isNot(contains('日 本')));
  });

  test('supplementary-plane CJK splits on runes and copies without spaces', () {
    // U+20000 and U+20001 as the UTF-16 code units PDFium reports.
    final chars = <PdfChar>[
      ..._line('A', 72, 650),
      ..._line('\uD840', 79.6, 650),
      ..._line('\uDC00', 86.2, 650),
      ..._line('\uD840', 92.8, 650),
      ..._line('\uDC01', 99.4, 650),
      ..._line('B', 106, 650),
      ..._line('body text follows', 72, 636),
    ];
    final bitmap = img.Image(width: 400, height: 400);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    _paintChars(bitmap, chars, img.ColorRgb8(10, 10, 10));

    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );

    final words = page.blocks
        .whereType<PdfReflowParagraph>()
        .expand((p) => p.lines)
        .expand((l) => l.words)
        .map((w) => w.text)
        .toList();
    expect(words, containsAllInOrder(<String>['A', '𠀀', '𠀁', 'B']));
    final paragraph = page.blocks.whereType<PdfReflowParagraph>().first;
    expect(paragraph.text, contains('A 𠀀𠀁B'));
    expect(paragraph.text, isNot(contains('𠀀 𠀁')));
  });

  test('glyph masks follow a dark background instead of turning solid', () {
    final chars = _line('Inverted words on a panel', 72, 650);
    final bitmap = img.Image(width: 800, height: 500);
    img.fill(bitmap, color: img.ColorRgb8(24, 26, 30));
    for (final char in chars) {
      // Reversed-out type: a thin light stroke on the dark panel, so most of
      // the crop is background.
      final top = (792 - char.top).round();
      final bottom = (792 - char.bottom).round();
      img.fillRect(
        bitmap,
        x1: char.left.round(),
        y1: top + 3,
        x2: char.right.round(),
        y2: bottom - 4,
        color: img.ColorRgb8(240, 238, 232),
      );
    }

    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    expect(page.hasText, isTrue);

    final atlas = img.decodePng(page.atlasPng!)!;
    final word = page.blocks
        .whereType<PdfReflowParagraph>()
        .expand((paragraph) => paragraph.lines)
        .expand((line) => line.words)
        .first;
    // The crop's edge is panel, not ink; the old white-background inversion
    // made every pixel of the crop opaque.
    expect(atlas.getPixel(word.atlasX, word.atlasY).a, 0);

    var peak = 0;
    var inked = 0;
    for (var y = 0; y < word.atlasHeight; y++) {
      for (var x = 0; x < word.atlasWidth; x++) {
        final alpha = atlas.getPixel(word.atlasX + x, word.atlasY + y).a;
        if (alpha > peak) peak = alpha.toInt();
        if (alpha > 32) inked++;
      }
    }
    // The light strokes are ink, and the rest of the crop is transparent.
    expect(peak, greaterThan(150));
    expect(inked / (word.atlasWidth * word.atlasHeight), lessThan(0.5));
  });

  test('an oversized word crop is clamped, not squashed', () {
    // 1200 characters at 12 pt span ~7900 pt, far wider than the atlas.
    final chars = _line('a' * 1200, 60, 650);
    final bitmap = img.Image(width: 8100, height: 400);
    img.fill(bitmap, color: img.ColorRgb8(255, 255, 255));
    _paintChars(bitmap, chars, img.ColorRgb8(10, 10, 10));

    final page = buildPdfReflowPage(
      chars: chars,
      images: const <PdfImagePlacement>[],
      bitmap: bitmap,
      renderScale: 1,
      pageWidth: 612,
      pageHeight: 792,
    );
    expect(page.hasText, isTrue);

    final atlas = img.decodePng(page.atlasPng!)!;
    expect(atlas.width, lessThanOrEqualTo(4096));
    final word = page.blocks
        .whereType<PdfReflowParagraph>()
        .expand((paragraph) => paragraph.lines)
        .expand((line) => line.words)
        .first;
    expect(word.atlasWidth, lessThan(7900));
    // The sprite rect covers exactly the pixels written to the atlas; before
    // the clamp it claimed the full 7900 pt span and the reader squashed the
    // clipped glyph into it.
    expect(word.widthPoints, closeTo(word.atlasWidth.toDouble(), 0.001));
    expect(word.heightPoints, closeTo(word.atlasHeight.toDouble(), 0.001));
  });
}

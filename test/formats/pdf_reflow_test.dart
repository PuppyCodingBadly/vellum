import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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
    expect(
      paragraphs.expand((p) => p.text.split(' ')),
      isNot(contains('9')),
    );
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
  });
}

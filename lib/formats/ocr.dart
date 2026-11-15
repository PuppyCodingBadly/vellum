/// Tesseract OCR: page layout and word bounds for pages without a text layer.
///
/// Scanned pages carry no PDF text objects, so PDFium returns no character
/// boxes and the reflow reader has nothing to lay out. Tesseract reports one
/// row per word with its bounding box plus block/paragraph/line ids, which is
/// the same geometry the text-layer path gets from PDFium — only the text is
/// recognized instead of stored.
///
/// The engine is a CLI process, not an FFI binding: tesseract ships its own
/// language data and the CLI's TSV output is a stable, documented format.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A failure from the OCR engine, safe to show in the reader.
class OcrException implements Exception {
  const OcrException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One recognized word, in image pixels measured from the top-left.
///
/// Tesseract's ids are kept because they carry the layout analysis: words in
/// one paragraph share [paragraph] within a [block], and one printed line
/// shares [line]. Reflow uses those ids instead of guessing line breaks from
/// glyph gaps.
class OcrWord {
  const OcrWord({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.block,
    required this.paragraph,
    required this.line,
    required this.confidence,
  });

  final String text;
  final int left;
  final int top;
  final int width;
  final int height;

  final int block;
  final int paragraph;
  final int line;

  /// Tesseract confidence in `0..100`.
  final double confidence;

  int get right => left + width;
  int get bottom => top + height;

  /// Why a word starts where it does in the reflowed line.
  ///
  /// Tesseract separates words with spaces; scripts without spaces still
  /// arrive as separate rows for some languages, and joining those with a
  /// space would corrupt the text.
  bool get isWideScript => text.runes.every(_isWideCharacter);
}

/// A page of recognized words in Tesseract's reading order.
class OcrLayout {
  const OcrLayout({
    required this.words,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// Words in the order Tesseract emitted them, which is reading order.
  final List<OcrWord> words;
  final int imageWidth;
  final int imageHeight;

  bool get isEmpty => words.isEmpty;

  /// Parses `tesseract … tsv` output.
  ///
  /// Every non-word row (page, block, paragraph, line) is ignored, as are
  /// rows whose confidence is negative or whose box is empty. Text is the
  /// last column and may itself contain tabs, so it is joined back together.
  /// Malformed rows are skipped: a single bad row must not lose a page.
  static List<OcrWord> wordsFromTsv(String tsv) {
    final words = <OcrWord>[];
    for (final raw in const LineSplitter().convert(tsv)) {
      final row = raw.split('\t');
      if (row.length < 12) continue;
      final level = int.tryParse(row[0]);
      if (level != 5) continue;
      final block = int.tryParse(row[2]);
      final paragraph = int.tryParse(row[3]);
      final line = int.tryParse(row[4]);
      final left = int.tryParse(row[6]);
      final top = int.tryParse(row[7]);
      final width = int.tryParse(row[8]);
      final height = int.tryParse(row[9]);
      final confidence = double.tryParse(row[10]);
      final text = row.sublist(11).join('\t').trim();
      if (block == null ||
          paragraph == null ||
          line == null ||
          left == null ||
          top == null ||
          width == null ||
          height == null ||
          confidence == null ||
          confidence < 0 ||
          width <= 0 ||
          height <= 0 ||
          text.isEmpty) {
        continue;
      }
      words.add(
        OcrWord(
          text: text,
          left: left,
          top: top,
          width: width,
          height: height,
          block: block,
          paragraph: paragraph,
          line: line,
          confidence: confidence,
        ),
      );
    }
    return words;
  }
}

bool _isWideCharacter(int code) =>
    (code >= 0x2E80 && code <= 0x2FFF) || // CJK radicals
    (code >= 0x3000 && code <= 0x303F) || // CJK punctuation
    (code >= 0x3040 && code <= 0x30FF) || // Hiragana/Katakana
    (code >= 0x3100 && code <= 0x312F) || // Bopomofo
    (code >= 0x31C0 && code <= 0x31EF) || // CJK strokes
    (code >= 0x3400 && code <= 0x4DBF) || // CJK Extension A
    (code >= 0x4E00 && code <= 0x9FFF) || // CJK Unified
    (code >= 0xAC00 && code <= 0xD7AF) || // Hangul
    (code >= 0xF900 && code <= 0xFAFF) || // CJK Compatibility
    (code >= 0xFF00 && code <= 0xFFEF) || // Fullwidth forms
    (code >= 0x20000 && code <= 0x2FA1F); // CJK Extensions B–F

/// Pluggable recognition backend.
///
/// [PdfBook] takes one so tests can supply word boxes without a Tesseract
/// installation; production uses [TesseractOcr].
abstract class OcrEngine {
  /// Recognizes [png] (a page raster of [imageWidth]×[imageHeight] pixels).
  Future<OcrLayout> recognize(
    Uint8List png, {
    required int imageWidth,
    required int imageHeight,
    required double dpi,
  });
}

/// Runs the `tesseract` CLI and parses its TSV output.
///
/// Resolution order for the binary: `VELLUM_TESSERACT`, then the Flatpak
/// install at `/app/bin/tesseract`, then `tesseract` on `PATH`. The language
/// is `VELLUM_OCR_LANG` unless the constructor overrides it; multiple
/// languages use Tesseract's `eng+deu` syntax.
class TesseractOcr implements OcrEngine {
  TesseractOcr({
    String? executable,
    String? language,
    this.timeout = const Duration(seconds: 20),
  }) : _executable =
           executable ??
           Platform.environment['VELLUM_TESSERACT'] ??
           _defaultExecutable(),
       language = language ?? Platform.environment['VELLUM_OCR_LANG'] ?? 'eng';

  /// How long one page may take before the process is killed.
  final Duration timeout;

  /// Tesseract language(s), in its `eng` or `eng+deu` syntax.
  final String language;

  final String _executable;

  static String _defaultExecutable() {
    const bundled = '/app/bin/tesseract';
    return File(bundled).existsSync() ? bundled : 'tesseract';
  }

  @override
  Future<OcrLayout> recognize(
    Uint8List png, {
    required int imageWidth,
    required int imageHeight,
    required double dpi,
  }) async {
    if (png.isEmpty) throw const OcrException('The page image was empty.');
    final args = <String>[
      'stdin',
      'stdout',
      '-l',
      language,
      '--psm',
      '3',
      '--dpi',
      dpi.round().clamp(70, 1200).toString(),
      'tsv',
    ];
    final Process process;
    try {
      process = await Process.start(_executable, args);
    } on ProcessException {
      throw const OcrException(
        'OCR is unavailable: install tesseract-ocr to read scanned pages.',
      );
    }

    final stdoutBytes = process.stdout
        .fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) => builder..add(chunk),
        )
        .then((builder) => builder.takeBytes());
    final stderrBytes = process.stderr.fold<List<int>>(<int>[], (bytes, chunk) {
      final remaining = 8192 - bytes.length;
      if (remaining > 0) {
        bytes.addAll(
          chunk.length > remaining ? chunk.sublist(0, remaining) : chunk,
        );
      }
      return bytes;
    });
    // Ignore a broken pipe: the process may exit before it consumes the image,
    // and its exit status already carries the real failure.
    unawaited(
      process.stdin
          .addStream(Stream<Uint8List>.value(png))
          .then((_) => process.stdin.close())
          .catchError((Object _) {}),
    );

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      // Drain both pipes so the killed process's buffers are released before
      // the failure reaches the reader.
      try {
        await stdoutBytes;
      } catch (_) {}
      try {
        await stderrBytes;
      } catch (_) {}
      throw OcrException('OCR took longer than ${timeout.inSeconds} seconds.');
    }
    final bytes = await stdoutBytes;
    if (exitCode != 0) {
      final stderr = utf8.decode(await stderrBytes, allowMalformed: true);
      final lower = stderr.toLowerCase();
      // Tesseract's own message carries paths and library internals; turn it
      // into something the reader can act on.
      final message =
          lower.contains('traineddata') || lower.contains('read_params_file')
          ? 'OCR language data is missing or unreadable.'
          : lower.contains('failed') ||
                lower.contains('could not initialize') ||
                lower.contains('error')
          ? 'The OCR engine failed to read this page.'
          : 'The OCR engine failed.';
      throw OcrException(message);
    }
    return OcrLayout(
      words: OcrLayout.wordsFromTsv(utf8.decode(bytes, allowMalformed: true)),
      imageWidth: imageWidth,
      imageHeight: imageHeight,
    );
  }
}

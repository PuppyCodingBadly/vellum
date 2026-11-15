/// Tests for the Tesseract CLI bridge and its TSV layout parser.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vellum/formats/ocr.dart';

const _header =
    'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\t'
    'left\ttop\twidth\theight\tconf\ttext';

String _row(
  String level,
  String block,
  String paragraph,
  String line,
  String left,
  String top,
  String width,
  String height,
  String confidence,
  String text,
) =>
    '$level\t1\t$block\t$paragraph\t$line\t1\t'
    '$left\t$top\t$width\t$height\t$confidence\t$text';

void main() {
  test('parses word rows and keeps Tesseract reading order', () {
    final words = OcrLayout.wordsFromTsv(
      <String>[
        _header,
        _row('1', '0', '0', '0', '0', '0', '800', '1000', '-1', ''),
        _row('4', '1', '1', '1', '72', '120', '300', '24', '-1', ''),
        _row('5', '1', '1', '1', '72', '120', '50', '24', '96.5', 'First'),
        _row('5', '1', '1', '1', '130', '120', '60', '24', '94.1', 'line'),
        _row('5', '1', '1', '2', '72', '150', '80', '22', '91', 'second'),
      ].join('\n'),
    );

    expect(words.map((word) => word.text), ['First', 'line', 'second']);
    expect(words.first.block, 1);
    expect(words.first.paragraph, 1);
    expect(words.first.line, 1);
    expect(words.first.left, 72);
    expect(words.first.width, 50);
    expect(words.first.confidence, 96.5);
    expect(words.last.line, 2);
  });

  test('skips malformed, empty, and negative-confidence rows', () {
    final words = OcrLayout.wordsFromTsv(
      <String>[
        _header,
        'garbage',
        _row('5', '1', '1', '1', '0', '0', '0', '20', '90', 'zeroWidth'),
        _row('5', '1', '1', '1', '0', '0', '20', '20', '-1', 'lowConf'),
        _row('5', '1', '1', '1', '0', '0', '20', '20', '90', ''),
        _row('5', '1', '1', '1', '0', '0', '20', '20', '90', 'kept'),
      ].join('\n'),
    );

    expect(words.map((word) => word.text), ['kept']);
  });

  test('a word text may contain tabs and is joined back', () {
    final words = OcrLayout.wordsFromTsv(
      '$_header\n${_row('5', '1', '1', '1', '0', '0', '20', '20', '90', 'a\tb')}',
    );
    expect(words.single.text, 'a\tb');
  });

  test('wide-script runs and Latin words are distinguishable', () {
    OcrWord word(String text) => OcrWord(
      text: text,
      left: 0,
      top: 0,
      width: 10,
      height: 10,
      block: 1,
      paragraph: 1,
      line: 1,
      confidence: 90,
    );

    expect(word('漢字').isWideScript, isTrue);
    expect(word('かな').isWideScript, isTrue);
    expect(word('。').isWideScript, isTrue);
    expect(word('！').isWideScript, isTrue);
    expect(word('Hello').isWideScript, isFalse);
    expect(word('漢a').isWideScript, isFalse);
  });

  group('the CLI bridge', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ocr-cli-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String script(String body) {
      final path = '${tmp.path}/tesseract';
      File(path).writeAsStringSync('#!/bin/sh\n$body\n');
      final chmod = Process.runSync('chmod', <String>['+x', path]);
      expect(chmod.exitCode, 0);
      return path;
    }

    test('passes the page on stdin and parses stdout as TSV', () async {
      final tsv = '${tmp.path}/page.tsv';
      File(tsv).writeAsStringSync(
        <String>[
          _header,
          _row('5', '2', '1', '1', '10', '20', '30', '40', '88', 'OCR'),
          _row('5', '2', '1', '1', '50', '20', '30', '40', '80', 'words'),
        ].join('\n'),
      );
      final argsFile = '${tmp.path}/args.txt';
      final executable = script(
        'cat > /dev/null\n'
        'printf "%s\\n" "\$@" > "$argsFile"\n'
        'cat "$tsv"',
      );

      final layout = await TesseractOcr(executable: executable, language: 'eng')
          .recognize(
            Uint8List.fromList([1, 2, 3, 4]),
            imageWidth: 640,
            imageHeight: 480,
            dpi: 216,
          );

      expect(layout.words.map((word) => word.text), ['OCR', 'words']);
      expect(layout.imageWidth, 640);
      expect(layout.imageHeight, 480);
      expect(
        File(argsFile).readAsLinesSync(),
        containsAllInOrder(<String>[
          'stdin',
          'stdout',
          '-l',
          'eng',
          '--psm',
          '3',
          '--dpi',
          '216',
          'tsv',
        ]),
      );
    });

    test('a missing binary reports how to install OCR', () async {
      await expectLater(
        TesseractOcr(executable: '${tmp.path}/does-not-exist').recognize(
          Uint8List.fromList([1]),
          imageWidth: 1,
          imageHeight: 1,
          dpi: 72,
        ),
        throwsA(
          isA<OcrException>().having(
            (error) => error.message,
            'message',
            contains('install tesseract-ocr'),
          ),
        ),
      );
    });

    test('a failed run reports a reader-safe message', () async {
      final executable = script(
        'cat > /dev/null\n'
        "echo \"Failed loading language 'xyz'\" >&2\n"
        'exit 2',
      );

      await expectLater(
        TesseractOcr(executable: executable, language: 'xyz').recognize(
          Uint8List.fromList([1]),
          imageWidth: 1,
          imageHeight: 1,
          dpi: 72,
        ),
        throwsA(
          isA<OcrException>().having(
            (error) => error.message,
            'message',
            'The OCR engine failed to read this page.',
          ),
        ),
      );
    });

    test('language-data errors hide the stderr path', () async {
      final executable = script(
        'cat > /dev/null\n'
        'echo "Error opening data file /app/share/tessdata/xyz.traineddata" >&2\n'
        'exit 1',
      );

      await expectLater(
        TesseractOcr(executable: executable, language: 'xyz').recognize(
          Uint8List.fromList([1]),
          imageWidth: 1,
          imageHeight: 1,
          dpi: 72,
        ),
        throwsA(
          isA<OcrException>().having(
            (error) => error.message,
            'message',
            allOf(contains('language data'), isNot(contains('/app'))),
          ),
        ),
      );
    });

    test('malformed stderr bytes still fail with OcrException', () async {
      final executable = script("cat > /dev/null\nprintf '\\377' >&2\nexit 1");

      await expectLater(
        TesseractOcr(executable: executable).recognize(
          Uint8List.fromList([1]),
          imageWidth: 1,
          imageHeight: 1,
          dpi: 72,
        ),
        throwsA(isA<OcrException>()),
      );
    });

    test('a slow run is killed at the deadline', () async {
      final executable = script('sleep 5\ncat > /dev/null');

      await expectLater(
        TesseractOcr(
          executable: executable,
          timeout: const Duration(milliseconds: 100),
        ).recognize(
          Uint8List.fromList([1]),
          imageWidth: 1,
          imageHeight: 1,
          dpi: 72,
        ),
        throwsA(
          isA<OcrException>().having(
            (error) => error.message,
            'message',
            contains('longer than'),
          ),
        ),
      );
    });
  });
}

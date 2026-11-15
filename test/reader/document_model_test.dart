import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/reader/document_model.dart';

void main() {
  test('pre nested in blockquote preserves newlines and spaces', () {
    final doc = DocumentModel.fromHtml(
      '<blockquote><pre>line1\nline2  spaced</pre></blockquote>',
      baseDirectory: '/tmp',
    );
    expect(doc.plainText, contains('line1\nline2  spaced'));
  });

  test('a named anchor does not turn the chapter into a link', () {
    final doc = DocumentModel.fromHtml(
      '<body><h2><a id="chap01"/>CHAPTER I.</h2>'
      '<p>Plain paragraph text.</p></body>',
      baseDirectory: '/tmp',
    );
    final span = doc.buildSpan(
      baseStyle: const TextStyle(color: Colors.black, fontSize: 16),
      linkColor: Colors.teal,
    );
    final text = <String, TextStyle?>{};
    void walk(InlineSpan node) {
      if (node is! TextSpan) return;
      if ((node.text ?? '').isNotEmpty) text[node.text!] = node.style;
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(span);
    for (final entry in text.entries) {
      expect(
        entry.value?.decoration,
        isNot(TextDecoration.underline),
        reason: '${entry.key} must not be a link',
      );
    }
  });

  test('a real hyperlink keeps the link styling', () {
    final doc = DocumentModel.fromHtml(
      '<p>Read <a href="https://example.com">this</a>.</p>',
      baseDirectory: '/tmp',
    );
    final span = doc.buildSpan(
      baseStyle: const TextStyle(color: Colors.black, fontSize: 16),
      linkColor: Colors.teal,
    );
    TextStyle? linked;
    void walk(InlineSpan node) {
      if (node is! TextSpan) return;
      if ((node.text ?? '').trim() == 'this') linked = node.style;
      for (final child in node.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }

    walk(span);
    expect(linked?.decoration, TextDecoration.underline);
    expect(linked?.color, Colors.teal);
  });

  group('image sources are contained', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('document-model-images-');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    File image(String path) =>
        File(path)..writeAsBytesSync(const <int>[0x89, 0x50, 0x4E, 0x47]);

    test('a relative source inside the chapter directory resolves', () {
      final chapters = Directory('${tmp.path}/OEBPS/Text')
        ..createSync(recursive: true);
      final picture = image('${chapters.path}/pic.png');

      final doc = DocumentModel.fromHtml(
        '<p>x</p><img src="pic.png" alt="pic">',
        baseDirectory: chapters.path,
      );

      expect(doc.images.single.path, picture.resolveSymbolicLinksSync());
      expect(doc.images.single.alt, 'pic');
    });

    test('parent traversal, absolute paths and missing files are dropped', () {
      final chapters = Directory('${tmp.path}/OEBPS/Text')
        ..createSync(recursive: true);
      image('${tmp.path}/OEBPS/secret.png');

      final doc = DocumentModel.fromHtml(
        '<img src="../secret.png">'
        '<img src="/etc/passwd">'
        '<img src="file:///etc/passwd">'
        '<img src="missing.png">'
        '<img src="https://example.com/x.png">',
        baseDirectory: chapters.path,
      );

      expect(doc.images, hasLength(5));
      expect([
        for (final picture in doc.images) picture.path,
      ], everyElement(isNull));
    });

    test('rootDirectory allows sibling directories but not escapes', () {
      final book = Directory('${tmp.path}/book')..createSync();
      final text = Directory('${book.path}/Text')..createSync();
      final images = Directory('${book.path}/Images')..createSync();
      final cover = image('${images.path}/cover.png');
      image('${tmp.path}/outside.png');

      final doc = DocumentModel.fromHtml(
        '<img src="../Images/cover.png"><img src="../../outside.png">',
        baseDirectory: text.path,
        rootDirectory: book.path,
      );

      expect(doc.images[0].path, cover.resolveSymbolicLinksSync());
      expect(doc.images[1].path, isNull);
    });

    test('a malformed percent escape keeps the literal file name', () {
      final chapters = Directory('${tmp.path}/chapter')..createSync();
      final picture = image('${chapters.path}/100%zz.png');

      final doc = DocumentModel.fromHtml(
        '<img src="100%zz.png">',
        baseDirectory: chapters.path,
      );

      expect(doc.images.single.path, picture.resolveSymbolicLinksSync());
    });
  });
}

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
}

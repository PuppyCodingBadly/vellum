/// HTML → plain text conversion — port of calibre.py's _html_to_text.
/// Shared by calibre import and FTS indexing.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as htmlparser;

const _blockTags = {
  'address', 'article', 'aside', 'blockquote', 'br', 'dd', 'div', 'dl',
  'dt', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3', 'h4', 'h5',
  'h6', 'header', 'hr', 'li', 'main', 'nav', 'ol', 'p', 'pre', 'section',
  'table', 'tr', 'ul',
};
const _skipTags = {'script', 'style'};

/// Turn HTML markup into plain-text paragraphs: script/style content is
/// skipped, block tags become newlines, <td> becomes a space, whitespace
/// collapses per line, and empty lines are dropped.
String htmlToText(String markup) {
  // package:html's tree constructor drops <td>/<th> outside table context
  // (a streaming parser like the Python contract's HTMLParser keeps them),
  // so substitute stray cell tags before parsing: each start tag becomes a
  // space, end tags vanish. Skipped when a real <table> is present so
  // genuine cells keep their normal handling.
  var input = markup;
  if (!markup.toLowerCase().contains('<table')) {
    input = input
        .replaceAll(RegExp(r'<(?:td|th)(?=[\s>/])[^>]*>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'</(?:td|th)\s*>', caseSensitive: false), '');
  }
  final doc = htmlparser.parse(input);
  final parts = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      parts.write(node.data);
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (_skipTags.contains(tag)) return; // skip whole subtree
      if (_blockTags.contains(tag)) {
        parts.write('\n');
      } else if (tag == 'td') {
        parts.write(' ');
      }
      for (final child in node.nodes) {
        walk(child);
      }
      if (_blockTags.contains(tag)) parts.write('\n');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  for (final child in doc.nodes) {
    walk(child);
  }
  final lines = parts
      .toString()
      .split(RegExp(r'\r\n?|\n'))
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty);
  return lines.join('\n');
}

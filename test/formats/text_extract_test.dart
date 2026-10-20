/// Tests for vellum formats/text_extract.dart (port of calibre.py's
/// _html_to_text semantics).
library;

import 'package:test/test.dart';
import 'package:vellum/formats/text_extract.dart';

void main() {
  test('paragraphs and entity unescaping', () {
    expect(htmlToText('<p>One</p><p>Two &amp; three</p>'),
        'One\nTwo & three');
  });

  test('script and style content is skipped', () {
    expect(
      htmlToText('<p>Keep</p><script>var x = 1;</script>'
          '<style>.a { color: red; }</style><p>Also</p>'),
      'Keep\nAlso',
    );
  });

  test('whitespace collapses per line, empty lines dropped', () {
    expect(htmlToText('<p>a   b</p>\n\n\n<p>  c </p>'), 'a b\nc');
  });

  test('td becomes a space, br becomes a newline', () {
    expect(htmlToText('<table><tr><td>a</td><td>b</td></tr></table>'), 'a b');
    expect(htmlToText('one<br>two'), 'one\ntwo');
  });

  test('headings are block tags', () {
    expect(htmlToText('<h1>Title</h1><p>Body</p>'), 'Title\nBody');
  });

  test('empty input yields empty output', () {
    expect(htmlToText(''), '');
    expect(htmlToText('<script>only</script>'), '');
  });
}

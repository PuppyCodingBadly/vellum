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
}

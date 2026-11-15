/// Tests for the shared path containment helper.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:vellum/core/safe_paths.dart';

void main() {
  group('relativePathSegments', () {
    test('collapses separators and dot segments', () {
      expect(relativePathSegments('a//b/./c'), ['a', 'b', 'c']);
      expect(relativePathSegments(r'a\b\c'), ['a', 'b', 'c']);
    });

    test('rejects absolute, empty and climbing paths', () {
      for (final path in [
        '/etc/passwd',
        r'\etc\passwd',
        'C:/windows/system32',
        '../etc/passwd',
        'a/../../b',
        r'..\..\b',
        '',
        '.',
        '/',
      ]) {
        expect(relativePathSegments(path), isNull, reason: path);
      }
    });
  });

  test('decodePercentEscapes keeps malformed escapes literal', () {
    expect(decodePercentEscapes('a%20b.png'), 'a b.png');
    expect(decodePercentEscapes('cover%zz.png'), 'cover%zz.png');
  });

  group('ContainedRoot', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('safe-paths-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('resolves relative files and non-existing paths under the root', () {
      final root = ContainedRoot.resolve(tmp.path)!;
      final file = File('${tmp.path}/book.txt')..writeAsStringSync('x');

      expect(root.file('book.txt'), file.resolveSymbolicLinksSync());
      expect(root.file('chapters/ch1.xhtml'), isNull);
      expect(
        root.path('chapters/ch1.xhtml'),
        '${root.directory}/chapters/ch1.xhtml',
      );
      expect(root.file('missing.txt'), isNull);
    });

    test('rejects absolute paths and parent traversal', () {
      final root = ContainedRoot.resolve(tmp.path)!;

      expect(root.path('/etc/passwd'), isNull);
      expect(root.file('../outside.txt'), isNull);
      expect(root.file('nested/../../outside.txt'), isNull);
    });

    test('rejects a directory linked outside the root', () {
      // The root is a subdirectory of `tmp`, so the link target can genuinely
      // lie outside it while the whole fixture still lives under `tmp`.
      final rootDirectory = Directory('${tmp.path}/root')..createSync();
      final outside = Directory('${tmp.path}/outside')..createSync();
      final root = ContainedRoot.resolve(rootDirectory.path)!;
      File('${outside.path}/secret.txt').writeAsStringSync('x');
      Link('${rootDirectory.path}/link').createSync(outside.path);

      expect(root.path('link'), isNull);
      expect(root.path('link/secret.txt'), isNull);
      expect(root.path('link/missing.txt'), isNull);
      expect(root.file('link/secret.txt'), isNull);
      expect(root.file('link'), isNull);
    });

    test('accepts a file linked inside the root', () {
      final root = ContainedRoot.resolve(tmp.path)!;
      final target = File('${tmp.path}/real.txt')..writeAsStringSync('x');
      Link('${tmp.path}/alias.txt').createSync(target.path);

      expect(root.file('alias.txt'), target.resolveSymbolicLinksSync());
    });
  });
}

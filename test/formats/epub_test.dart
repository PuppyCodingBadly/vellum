/// Tests for vellum formats/epub.dart (mirrors tests/test_epub.py).
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:vellum/formats/epub.dart';

String _makeEpub(String path, {bool withNcx = true}) {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="cover.png" media-type="image/png"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="c2"/>
    <itemref idref="c1"/>
    <itemref idref="c3"/>
  </spine>
</package>''';
  const ncx = '''<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>Chapter One</text></navLabel>
      <content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel>
      <content src="ch2.xhtml"/></navPoint>
    <navPoint id="n3" playOrder="3"><navLabel><text>Chapter Three</text></navLabel>
      <content src="ch3.xhtml"/></navPoint>
  </navMap>
</ncx>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf));
  if (withNcx) {
    archive.addFile(ArchiveFile.string('OEBPS/toc.ncx', ncx));
  }
  for (final name in ['ch1', 'ch2', 'ch3']) {
    archive.addFile(ArchiveFile.string(
        'OEBPS/$name.xhtml', '<html><body><p>$name</p></body></html>'));
  }
  archive.addFile(ArchiveFile('OEBPS/cover.png', 8,
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('epub-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('chapters order and titles', () {
    final epub = EpubBook(_makeEpub('${tmp.path}/book.epub'));
    final chapters = epub.chapters();
    expect([for (final c in chapters) c.$1],
        ['ch2.xhtml', 'ch1.xhtml', 'ch3.xhtml']);
    expect([for (final c in chapters) c.$2],
        ['Chapter Two', 'Chapter One', 'Chapter Three']);
  });

  test('chapters fall back to stems without ncx', () {
    final epub = EpubBook(_makeEpub('${tmp.path}/book.epub', withNcx: false));
    final chapters = epub.chapters();
    expect([for (final c in chapters) c.$1],
        ['ch2.xhtml', 'ch1.xhtml', 'ch3.xhtml']);
    expect([for (final c in chapters) c.$2], ['ch2', 'ch1', 'ch3']);
  });

  test('extractTo is idempotent', () {
    final epub = EpubBook(_makeEpub('${tmp.path}/book.epub'));
    final dest = '${tmp.path}/extract';

    final opfDir = epub.extractTo(dest);
    expect(opfDir, Directory('$dest/OEBPS').absolute.path);
    expect(File('$opfDir/content.opf').existsSync(), isTrue);
    expect(File('$opfDir/cover.png').existsSync(), isTrue);

    // Second call skips re-extraction: remove a file, it must stay removed.
    File('$opfDir/content.opf').deleteSync();
    expect(epub.extractTo(dest), opfDir);
    expect(File('$opfDir/content.opf').existsSync(), isFalse);
  });

  test('chapterFile returns existing path', () {
    final epub = EpubBook(_makeEpub('${tmp.path}/book.epub'));
    final path = epub.chapterFile('${tmp.path}/extract', 0);
    expect(File(path).existsSync(), isTrue);
    expect(path.endsWith('ch2.xhtml'), isTrue);
    expect(path.startsWith('/'), isTrue);
  });

  test('encoded spine href resolves extracted file', () {
    final path = '${tmp.path}/encoded.epub';
    const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="c1" href="chapter%201.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/></spine>
</package>''';
    final archive = Archive()
      ..addFile(ArchiveFile.string('META-INF/container.xml', container))
      ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
      ..addFile(ArchiveFile.string(
          'OEBPS/chapter 1.xhtml', '<html><body>one</body></html>'));
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));

    final book = EpubBook(path);
    expect(book.chapters()[0].$1, 'chapter 1.xhtml');
    final chapter = book.chapterFile('${tmp.path}/extract', 0);
    expect(File(chapter).existsSync(), isTrue);
  });

  test('garbage file throws FormatException', () {
    final bad = File('${tmp.path}/garbage.epub')
      ..writeAsBytesSync('this is not a zip at all'.codeUnits);
    expect(() => EpubBook(bad.path), throwsFormatException);
  });

  test('zip without container throws FormatException', () {
    final bad = '${tmp.path}/notepub.epub';
    final archive = Archive()..addFile(ArchiveFile.string('random.txt', 'hello'));
    File(bad).writeAsBytesSync(ZipEncoder().encode(archive));
    expect(() => EpubBook(bad), throwsFormatException);
  });
}

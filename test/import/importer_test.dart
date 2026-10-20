/// Tests for EPUB metadata/cover extraction during import.
///
/// Mirrors /tmp/vellum/tests/test_importer.py.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/import/importer.dart';

void main() {
  late Directory tmp;
  late Library library;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-importer-test-');
    library = Library(p.join(tmp.path, 'vellum.db'));
  });

  tearDown(() {
    library.close();
    tmp.deleteSync(recursive: true);
  });

  File writeEpub(String path, Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach((name, data) {
      archive.addFile(ArchiveFile(name, data.length, data));
    });
    return File(path)..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  const pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  test('encoded cover href is found', () async {
    const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
    const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <manifest>
    <item id="cover" href="cover%20art.png" media-type="image/png"/>
  </manifest>
</package>''';
    final epub = p.join(tmp.path, 'encoded-cover.epub');
    writeEpub(epub, {
      'META-INF/container.xml': utf8.encode(container),
      'OEBPS/content.opf': utf8.encode(opf),
      'OEBPS/cover art.png': pngBytes,
    });

    final ids = await importPath(library, epub);
    expect(ids, hasLength(1));
    final book = library.getBook(ids.single)!;
    expect(book.coverPath, isNotEmpty);
    expect(p.extension(book.coverPath), '.png');
    expect(File(book.coverPath).readAsBytesSync(), pngBytes);
  });

  test('opf:scheme=ISBN identifier populates isbn', () async {
    const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:opf="http://www.idpf.org/2007/opf">
  <metadata>
    <dc:title>Scheme Book</dc:title>
    <dc:identifier opf:scheme="ISBN">urn:isbn:9781234567890</dc:identifier>
    <dc:creator>Jane Author</dc:creator>
  </metadata>
</package>''';
    final epub = p.join(tmp.path, 'scheme.epub');
    writeEpub(epub, {'content.opf': utf8.encode(opf)});

    final ids = await importPath(library, epub);
    final book = library.getBook(ids.single)!;
    expect(book.title, 'Scheme Book');
    expect(book.isbn, '9781234567890');
    expect(book.authors, ['Jane Author']);
  });

  test('stem title fallback when opf has no title', () async {
    const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0"
         xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata>
    <dc:publisher>Acme</dc:publisher>
  </metadata>
</package>''';
    final epub = p.join(tmp.path, 'no-title-book.epub');
    writeEpub(epub, {'content.opf': utf8.encode(opf)});

    final ids = await importPath(library, epub);
    final book = library.getBook(ids.single)!;
    expect(book.title, 'no-title-book');
    expect(book.publisher, 'Acme');
  });

  test('malformed epub falls back to stem title and no cover', () async {
    final epub = p.join(tmp.path, 'broken.epub');
    File(epub).writeAsBytesSync(utf8.encode('this is not a zip'));

    final ids = await importPath(library, epub);
    expect(ids, hasLength(1));
    final book = library.getBook(ids.single)!;
    expect(book.title, 'broken');
    expect(book.formats, ['epub']);
    expect(book.coverPath, isEmpty);
  });

  test('unsupported file imports nothing', () async {
    final txt = p.join(tmp.path, 'notes.txt');
    File(txt).writeAsStringSync('hello');
    expect(await importPath(library, txt), isEmpty);
    expect(await importPath(library, p.join(tmp.path, 'missing.epub')), isEmpty);
  });

  test('directory imports supported files recursively and sorted', () async {
    final sub = Directory(p.join(tmp.path, 'library', 'nested'))
      ..createSync(recursive: true);
    File(p.join(sub.path, 'b.mobi')).writeAsBytesSync([1]);
    File(p.join(tmp.path, 'library', 'a.pdf')).writeAsBytesSync([2]);
    File(p.join(sub.path, 'skip.txt')).writeAsStringSync('x');

    final ids =
        await importPath(library, p.join(tmp.path, 'library'));
    expect(ids, hasLength(2));
    final titles = library.allBooks().map((b) => b.title).toSet();
    expect(titles, {'a', 'b'});
  });
}

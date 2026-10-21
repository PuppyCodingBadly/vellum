import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:vellum/core/db.dart';
import 'package:vellum/core/models.dart';
import 'package:vellum/fts/indexer.dart';

String _buildEpub() {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  const opf = '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>''';
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(ArchiveFile.string('META-INF/container.xml', container))
    ..addFile(ArchiveFile.string('OEBPS/content.opf', opf))
    ..addFile(ArchiveFile.string(
        'OEBPS/ch1.xhtml', '<html><body><p>moonstone alpha</p></body></html>'))
    ..addFile(ArchiveFile.string(
        'OEBPS/ch2.xhtml', '<html><body><p>moonstone beta</p></body></html>'));
  return base64Encode(ZipEncoder().encode(archive));
}

void main() {
  late Directory tmp;
  late Library library;
  late FtsIndexer indexer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vellum-fts-test');
    library = Library('${tmp.path}/library.db');
    indexer = FtsIndexer(library);
  });

  tearDown(() {
    library.close();
    tmp.deleteSync(recursive: true);
  });

  int addBookWithFile(String ext, List<int> bytes, {String title = 't'}) {
    final file = File('${tmp.path}/book-${DateTime.now().microsecondsSinceEpoch}.$ext');
    file.writeAsBytesSync(bytes);
    return library.addBook(Book(
      title: title,
      path: file.path,
      formats: [ext],
    ));
  }

  List<int> epubBytes() => base64Decode(_buildEpub());

  test('indexBook populates rows and search finds chapter with snippet',
      () async {
    final id = addBookWithFile('epub', epubBytes());
    await indexer.indexBook(id);
    final results = indexer.search('moonstone');
    expect(results, isNotEmpty);
    final row = results.firstWhere((r) => r['bookId'] == id || r['book_id'] == id);
    final snippet = (row['snippet'] ?? '').toString();
    expect(snippet, contains('<b>'));
  });

  test('unchanged book skipped on second indexAll', () async {
    addBookWithFile('epub', epubBytes());
    expect(await indexer.indexAll(), 1);
    expect(await indexer.indexAll(), 0);
  });

  test('changed mtime/size re-indexes', () async {
    final file = File('${tmp.path}/changing.epub');
    file.writeAsBytesSync(epubBytes());
    final id = library.addBook(Book(title: 't', path: file.path, formats: ['epub']));
    expect(await indexer.indexAll(), 1);
    file.writeAsBytesSync([...epubBytes(), 0]); // change size+mtime
    file.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    expect(await indexer.indexAll(), 1);
    expect(id, isNonZero);
  });

  test('garbage epub skipped without failing indexAll', () async {
    addBookWithFile('epub', epubBytes());
    addBookWithFile('epub', utf8.encode('this is not a zip at all'), title: 'bad');
    expect(await indexer.indexAll(), 1);
  });

  test('corrupt book is not counted by indexAll', () async {
    addBookWithFile('epub', utf8.encode('this is not a zip at all'), title: 'bad');
    expect(await indexer.indexAll(), 0);
  });

  test('extraction dirs are per-book and cleaned up after indexing', () async {
    addBookWithFile('epub', epubBytes());
    addBookWithFile('epub', epubBytes());
    await indexer.indexAll();
    final root = Directory('${tmp.path}/.fts-extract');
    if (root.existsSync()) {
      expect(root.listSync(), isEmpty);
    }
  });

  test('PDF-only book indexes zero rows', () async {
    final id = addBookWithFile('pdf', utf8.encode('%PDF-1.4 fake'));
    await indexer.indexBook(id);
    final results = indexer.search('fake');
    expect(results.where((r) => (r['bookId'] ?? r['book_id']) == id), isEmpty);
  });

  test('removeBook clears rows and state', () async {
    final id = addBookWithFile('epub', epubBytes());
    await indexer.indexBook(id);
    indexer.removeBook(id);
    final results = indexer.search('moonstone');
    expect(results.where((r) => (r['bookId'] ?? r['book_id']) == id), isEmpty);
  });
}

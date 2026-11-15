/// Import ebook files into a Library.
///
/// Ports `vellum/core/importer.py` (function `_read_epub`, `_find_cover`,
/// `import_path`). Synchronous internally; [importPath] is an async wrapper.
///
/// A file's canonical path is its source id, so importing the same file twice
/// (directly or through a directory scan) updates nothing and adds one row.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/db.dart';
import '../core/models.dart';
import '../formats/epub.dart';

/// File extensions (lowercase, with dot) that [importPath] accepts.
const supportedExtensions = {'.epub', '.mobi', '.pdf'};

const _dcNamespace = 'http://purl.org/dc/elements/1.1/';

/// Import a file or directory (recursively) into the library.
///
/// Returns the ids of the newly added books; files whose source id is already
/// in the library are skipped.
Future<List<int>> importPath(Library library, String path) async =>
    _importPath(library, path);

List<int> _importPath(Library library, String path) {
  final type = FileSystemEntity.typeSync(path);
  final ext = p.extension(path).toLowerCase();
  final List<File> files;
  if (type == FileSystemEntityType.directory) {
    files =
        Directory(path)
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (f) => supportedExtensions.contains(
                p.extension(f.path).toLowerCase(),
              ),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
  } else if (type == FileSystemEntityType.file &&
      supportedExtensions.contains(ext)) {
    files = [File(path)];
  } else {
    return [];
  }

  final ids = <int>[];
  for (final file in files) {
    try {
      final id = _importFile(library, file);
      if (id != null) ids.add(id);
    } catch (_) {
      // A single unreadable file must not abort the import.
      continue;
    }
  }
  return ids;
}

/// Import [file]; null when its source id is already in [library].
int? _importFile(Library library, File file) {
  final sourceId = 'file:${_realPath(file.path)}';
  if (library.findBySourceId(sourceId) != null) return null;

  final ext = p.extension(file.path).toLowerCase();
  final stem = p.basenameWithoutExtension(file.path);
  var title = stem;
  var authors = const <String>[];
  var isbn = '';
  var language = '';
  var publisher = '';
  var pubdate = '';
  var description = '';
  (String, List<int>)? cover;
  if (ext == '.epub') {
    try {
      final (meta, foundCover) = _readEpub(file);
      if (meta.title.isNotEmpty) title = meta.title;
      authors = meta.authors;
      isbn = meta.isbn;
      language = meta.language;
      publisher = meta.publisher;
      pubdate = meta.pubdate;
      description = meta.description;
      cover = foundCover;
    } catch (_) {
      // Malformed epub: keep the filename title and no cover.
    }
  }

  final book = Book(
    title: title,
    authors: authors,
    isbn: isbn,
    language: language,
    publisher: publisher,
    pubdate: pubdate,
    description: description,
    formats: [ext.substring(1)],
    path: file.path,
    sourceId: sourceId,
  );
  final bookId = library.addBook(book);
  if (cover != null) {
    try {
      book.coverPath = _storeCover(library, bookId, cover);
      library.updateBook(book);
    } catch (_) {
      // A failed cover write keeps the book without a cover.
    }
  }
  return bookId;
}

/// Canonical absolute path of [path], so the same file reached through a link
/// keeps one source id.
String _realPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

String _storeCover(Library library, int bookId, (String, List<int>) cover) {
  final (ext, data) = cover;
  final coversDir = Directory(p.join(library.baseDir, 'covers'))
    ..createSync(recursive: true);
  final dest = p.join(coversDir.path, '$bookId.$ext');
  File(dest).writeAsBytesSync(data);
  return dest;
}

String _stripIsbnPrefix(String text) {
  final lowered = text.toLowerCase();
  for (final prefix in ['urn:isbn:', 'isbn:']) {
    if (lowered.startsWith(prefix)) {
      return text.substring(prefix.length).trim();
    }
  }
  return text.trim();
}

class _EpubMeta {
  String title = '';
  final authors = <String>[];
  String isbn = '';
  String language = '';
  String publisher = '';
  String pubdate = '';
  String description = '';
}

/// Parse an epub, returning (metadata, (cover_ext, cover_bytes)?).
(_EpubMeta, (String, List<int>)?) _readEpub(File file) {
  final access = ArchiveAccess(
    ZipDecoder().decodeBytes(file.readAsBytesSync()),
  );

  // Locate the OPF via META-INF/container.xml.
  String? opfPath;
  final containerData = access.text('META-INF/container.xml');
  if (containerData != null) {
    XmlDocument? container;
    try {
      container = XmlDocument.parse(containerData);
    } on XmlException {
      container = null;
    }
    for (final rootfile
        in container?.findAllElements('rootfile') ?? const <XmlElement>[]) {
      final entry = access.entry('', rootfile.getAttribute('full-path') ?? '');
      if (entry != null) {
        opfPath = entry.name;
        break;
      }
    }
  }
  if (opfPath == null) {
    // Fallback: first .opf in the archive, sorted case-insensitively.
    final opfs =
        access.files
            .map((entry) => entry.name)
            .where((name) => name.toLowerCase().endsWith('.opf'))
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (opfs.isNotEmpty) opfPath = opfs.first;
  }
  if (opfPath == null) throw StateError('no OPF found');

  final opfData = access.text(opfPath);
  if (opfData == null) throw StateError('no readable OPF found');
  final opf = XmlDocument.parse(opfData);
  var opfDir = p.posix.dirname(opfPath);
  if (opfDir == '.') opfDir = '';

  final meta = _EpubMeta();
  var titleSet = false;
  var isbnSet = false;
  var languageSet = false;
  var publisherSet = false;
  var pubdateSet = false;
  var descriptionSet = false;
  for (final el in opf.descendantElements) {
    if (el.name.namespaceUri != _dcNamespace) continue;
    final text = el.innerText.trim();
    switch (el.name.local) {
      case 'title':
        if (text.isNotEmpty && !titleSet) {
          meta.title = text;
          titleSet = true;
        }
      case 'creator':
        if (text.isNotEmpty) meta.authors.add(text);
      case 'identifier':
        if (text.isNotEmpty) {
          final isIsbn =
              text.toLowerCase().contains('isbn') ||
              el.attributes.any((a) => a.value.trim().toLowerCase() == 'isbn');
          if (isIsbn && !isbnSet) {
            meta.isbn = _stripIsbnPrefix(text);
            isbnSet = true;
          }
        }
      case 'language':
        if (text.isNotEmpty && !languageSet) {
          meta.language = text;
          languageSet = true;
        }
      case 'publisher':
        if (text.isNotEmpty && !publisherSet) {
          meta.publisher = text;
          publisherSet = true;
        }
      case 'date':
        if (text.isNotEmpty && !pubdateSet) {
          meta.pubdate = text;
          pubdateSet = true;
        }
      case 'description':
        if (text.isNotEmpty && !descriptionSet) {
          meta.description = text;
          descriptionSet = true;
        }
    }
  }

  final cover = _findCover(access, opf, opfDir);
  return (meta, cover);
}

(String, List<int>)? _findCover(
  ArchiveAccess access,
  XmlDocument opf,
  String opfDir,
) {
  String? href;
  String? metaCoverId;
  // id -> (href, media-type, properties)
  final items = <String, (String, String, String)>{};
  for (final el in opf.descendantElements) {
    switch (el.name.local) {
      case 'item':
        items[el.getAttribute('id') ?? ''] = (
          el.getAttribute('href') ?? '',
          el.getAttribute('media-type') ?? '',
          el.getAttribute('properties') ?? '',
        );
      case 'meta':
        if (el.getAttribute('name') == 'cover') {
          metaCoverId = el.getAttribute('content');
        }
    }
  }

  // 1. EPUB3: manifest item with properties="cover-image".
  for (final (h, _, props) in items.values) {
    if (props.split(RegExp(r'\s+')).contains('cover-image') && h.isNotEmpty) {
      href = h;
      break;
    }
  }
  // 2. EPUB2: <meta name="cover" content="item-id">.
  if (href == null && metaCoverId != null && items.containsKey(metaCoverId)) {
    href = items[metaCoverId]!.$1;
  }
  // 3. Any manifest image whose id or href mentions "cover".
  if (href == null) {
    for (final entry in items.entries) {
      final (h, mediaType, _) = entry.value;
      if (mediaType.startsWith('image/') &&
          (entry.key.toLowerCase().contains('cover') ||
              h.toLowerCase().contains('cover'))) {
        href = h;
        break;
      }
    }
  }
  if (href == null || href.isEmpty) return null;

  // A hostile or malformed href must not abort the whole import: it simply
  // has no cover. [ArchiveAccess.entry] rejects `..`, absolutes and `%zz`.
  final entry = access.entry(opfDir, href);
  final data = entry == null ? null : access.bytes(entry.name);
  if (data == null) return null;
  final rel = ocfRelativePath(href) ?? href;
  var ext = p.posix.extension(rel);
  ext = (ext.startsWith('.') ? ext.substring(1) : ext).toLowerCase();
  if (ext.isEmpty) ext = 'jpg';
  return (ext, data);
}

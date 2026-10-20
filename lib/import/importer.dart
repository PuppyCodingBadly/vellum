/// Import ebook files into a Library.
///
/// Ports `vellum/core/importer.py` (function `_read_epub`, `_find_cover`,
/// `import_path`). Synchronous internally; [importPath] is an async wrapper.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../core/db.dart';
import '../core/models.dart';

/// File extensions (lowercase, with dot) that [importPath] accepts.
const supportedExtensions = {'.epub', '.mobi', '.pdf'};

const _dcNamespace = 'http://purl.org/dc/elements/1.1/';

/// Import a file or directory (recursively) into the library.
///
/// Returns the ids of newly added books.
Future<List<int>> importPath(Library library, String path) async =>
    _importPath(library, path);

List<int> _importPath(Library library, String path) {
  final type = FileSystemEntity.typeSync(path);
  final ext = p.extension(path).toLowerCase();
  final List<File> files;
  if (type == FileSystemEntityType.directory) {
    files = Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .where(
            (f) => supportedExtensions.contains(p.extension(f.path).toLowerCase()))
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
      ids.add(_importFile(library, file));
    } catch (_) {
      // A single unreadable file must not abort the import.
      continue;
    }
  }
  return ids;
}

int _importFile(Library library, File file) {
  final ext = p.extension(file.path).toLowerCase();
  final stem = p.basenameWithoutExtension(file.path);
  var book = Book(title: stem, formats: [ext.substring(1)], path: file.path);
  (String, List<int>)? cover;
  if (ext == '.epub') {
    try {
      final (meta, foundCover) = _readEpub(file);
      if (meta.title.isNotEmpty) book.title = meta.title;
      if (meta.authors.isNotEmpty) book.authors = meta.authors;
      if (meta.isbn.isNotEmpty) book.isbn = meta.isbn;
      if (meta.language.isNotEmpty) book.language = meta.language;
      if (meta.publisher.isNotEmpty) book.publisher = meta.publisher;
      if (meta.pubdate.isNotEmpty) book.pubdate = meta.pubdate;
      if (meta.description.isNotEmpty) book.description = meta.description;
      cover = foundCover;
      if (book.title.isEmpty) book.title = stem;
    } catch (_) {
      // Malformed epub; use the filename title and no cover.
      book = Book(title: stem, formats: [ext.substring(1)], path: file.path);
      cover = null;
    }
  }

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
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  final entries = <String, ArchiveFile>{for (final f in archive.files) f.name: f};

  // Locate the OPF via META-INF/container.xml.
  String? opfPath;
  final containerEntry = entries['META-INF/container.xml'];
  if (containerEntry != null) {
    final container =
        XmlDocument.parse(utf8.decode(containerEntry.readBytes()!));
    for (final rootfile in container.findAllElements('rootfile')) {
      final fullPath = rootfile.getAttribute('full-path');
      if (fullPath != null && entries.containsKey(fullPath)) {
        opfPath = fullPath;
        break;
      }
    }
  }
  if (opfPath == null) {
    // Fallback: first .opf in the archive, sorted case-insensitively.
    final opfs = entries.keys
        .where((n) => n.toLowerCase().endsWith('.opf'))
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (opfs.isNotEmpty) opfPath = opfs.first;
  }
  if (opfPath == null) throw StateError('no OPF found');

  final opf = XmlDocument.parse(utf8.decode(entries[opfPath]!.readBytes()!));
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
          final isIsbn = text.toLowerCase().contains('isbn') ||
              el.attributes
                  .any((a) => a.value.trim().toLowerCase() == 'isbn');
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

  final cover = _findCover(entries, opf, opfDir);
  return (meta, cover);
}

(String, List<int>)? _findCover(
    Map<String, ArchiveFile> entries, XmlDocument opf, String opfDir) {
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

  String resolve(String value) {
    final joined =
        opfDir.isEmpty ? value : p.posix.normalize(p.posix.join(opfDir, value));
    return joined.replaceAll('\\', '/');
  }

  var full = resolve(Uri.decodeComponent(href));
  if (!entries.containsKey(full)) {
    // Some EPUBs keep the encoded form as the ZIP entry name.
    full = resolve(href);
  }
  if (!entries.containsKey(full)) return null;
  final data = entries[full]!.readBytes()!;
  var ext = p.posix.extension(href);
  ext = (ext.startsWith('.') ? ext.substring(1) : ext).toLowerCase();
  if (ext.isEmpty) ext = 'jpg';
  return (ext, data);
}

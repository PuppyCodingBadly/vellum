/// Minimal EPUB (zip) parser — port of vellum/core/epub.py.
///
/// Everything the container declares is untrusted input: the OPF location,
/// spine hrefs and entry names. Hrefs are therefore normalized to
/// container-relative posix paths, entry bytes are read within fixed caps, and
/// every path handed to the filesystem is contained under the destination
/// directory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../core/safe_paths.dart';

const _containerPath = 'META-INF/container.xml';
const _marker = '.extracted';

/// Most bytes [ArchiveAccess] hands out for a single entry (64 MiB).
const maxEntryBytes = 64 << 20;

/// Most bytes one [ArchiveAccess] hands out in total (512 MiB).
const maxArchiveBytes = 512 << 20;

String _localname(XmlNode node) => node is XmlElement ? node.name.local : '';

/// [href] as a path relative to the directory that contains it, or null when
/// it is empty, absolute, or climbs out with `..`.
///
/// OCF stores hrefs URL-encoded, so they are percent-decoded (a malformed
/// escape keeps the raw text), the fragment is dropped, and `.`/`//` collapse.
String? ocfRelativePath(String href) {
  final hash = href.indexOf('#');
  final path = decodePercentEscapes(hash < 0 ? href : href.substring(0, hash));
  return relativePathSegments(path)?.join('/');
}

/// Bounded access to the entries of one EPUB container.
///
/// The zip declares each entry's uncompressed size, and reading materialises
/// that many bytes. [entryByteLimit] and [totalByteLimit] reject the reads
/// whose declared size (or actual result) is beyond what a book may consume,
/// so a crafted container cannot choose our allocations for us.
class ArchiveAccess {
  ArchiveAccess(
    Archive archive, {
    this.entryByteLimit = maxEntryBytes,
    this.totalByteLimit = maxArchiveBytes,
  }) : _entries = {
         for (final file in archive.files)
           if (file.isFile) file.name: file,
       };

  /// Per-entry byte cap.
  final int entryByteLimit;

  /// Cap on the sum of all bytes handed out by this instance.
  final int totalByteLimit;

  final Map<String, ArchiveFile> _entries;
  int _spent = 0;

  /// The files of the container (directories excluded).
  Iterable<ArchiveFile> get files => _entries.values;

  /// The entry [href] names relative to [baseDir], or null when the href is
  /// unsafe or names no entry.
  ///
  /// The percent-decoded name is tried first, as OCF specifies; the literal
  /// href is tried second because some writers store the encoded name in the
  /// zip.
  ArchiveFile? entry(String baseDir, String href) {
    for (final name in _candidateNames(baseDir, href)) {
      final entry = _entries[name];
      if (entry != null) return entry;
    }
    return null;
  }

  /// Bytes of the entry named [name], or null when it is missing, over a cap,
  /// or cannot be decoded.
  Uint8List? bytes(String name) {
    final entry = _entries[name];
    if (entry == null) return null;
    if (entry.size > entryByteLimit || _spent + entry.size > totalByteLimit) {
      return null;
    }
    final Uint8List data;
    try {
      data = entry.readBytes() ?? Uint8List(0);
    } catch (_) {
      return null; // corrupt entry: treat it as absent
    }
    if (data.length > entryByteLimit || _spent + data.length > totalByteLimit) {
      return null;
    }
    _spent += data.length;
    return data;
  }

  /// UTF-8 (lossy) text of the entry named [name]; null as for [bytes].
  String? text(String name) {
    final data = bytes(name);
    return data == null ? null : utf8.decode(data, allowMalformed: true);
  }

  Iterable<String> _candidateNames(String baseDir, String href) sync* {
    final base = baseDir.isEmpty ? const <String>[] : baseDir.split('/');
    final seen = <String>{};
    for (final variant in [decodePercentEscapes(href), href]) {
      final hash = variant.indexOf('#');
      final segments = relativePathSegments(
        hash < 0 ? variant : variant.substring(0, hash),
      );
      if (segments == null) continue;
      final name = [...base, ...segments].join('/');
      if (seen.add(name)) yield name;
    }
  }
}

class EpubBook {
  /// Parse an EPUB file: spine order, chapter titles, extraction.
  EpubBook(String path) {
    final List<int> bytes;
    try {
      bytes = File(path).readAsBytesSync();
    } on IOException catch (e) {
      throw FormatException('Not a valid epub file: $path', e);
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Not a valid epub file: $path', e);
    }
    _access = ArchiveAccess(archive);

    final containerData = _access.text(_containerPath);
    if (containerData == null) {
      throw FormatException('Not an epub (missing $_containerPath): $path');
    }
    final XmlDocument container;
    try {
      container = XmlDocument.parse(containerData);
    } on XmlException catch (e) {
      throw FormatException('Corrupt container.xml in: $path', e);
    }

    // A rootfile that is absolute, climbs out, or names no entry is not a
    // rootfile; the book has no readable OPF.
    ArchiveFile? opfEntry;
    for (final elem in container.descendants.whereType<XmlElement>()) {
      if (_localname(elem) != 'rootfile') continue;
      opfEntry = _access.entry('', elem.getAttribute('full-path') ?? '');
      if (opfEntry != null) break;
    }
    if (opfEntry == null) {
      throw FormatException('No OPF rootfile in container: $path');
    }
    _opfPath = opfEntry.name;
    final slash = _opfPath.lastIndexOf('/');
    _opfDir = slash < 0 ? '' : _opfPath.substring(0, slash);

    final opfData = _access.text(_opfPath);
    if (opfData == null) {
      throw FormatException('Corrupt OPF in: $path');
    }
    final XmlDocument opf;
    try {
      opf = XmlDocument.parse(opfData);
    } on XmlException catch (e) {
      throw FormatException('Corrupt OPF in: $path', e);
    }

    // manifest: id -> (href, media-type)
    final manifest = <String, (String, String)>{};
    final idrefs = <String>[];
    String? ncxHref;
    String? navHref;

    for (final elem in opf.descendants.whereType<XmlElement>()) {
      final name = _localname(elem);
      if (name == 'item') {
        final id = elem.getAttribute('id');
        final href = elem.getAttribute('href');
        if (id != null && id.isNotEmpty && href != null && href.isNotEmpty) {
          manifest[id] = (href, elem.getAttribute('media-type') ?? '');
          final props = (elem.getAttribute('properties') ?? '').split(' ');
          if (props.contains('nav')) navHref = href;
        }
      } else if (name == 'itemref') {
        final idref = elem.getAttribute('idref');
        if (idref != null && idref.isNotEmpty) idrefs.add(idref);
      } else if (name == 'spine') {
        final tocId = elem.getAttribute('toc');
        if (tocId != null && manifest.containsKey(tocId)) {
          ncxHref = manifest[tocId]!.$1;
        }
      }
    }

    // NCX fallback: find by media-type if spine toc attr missing.
    if (ncxHref == null) {
      for (final (href, mtype) in manifest.values) {
        if (mtype == 'application/x-dtbncx+xml') {
          ncxHref = href;
          break;
        }
      }
    }

    final spine = <({String href, String? entry})>[];
    for (final idref in idrefs) {
      final item = manifest[idref];
      if (item == null) continue;
      final (href, mtype) = item;
      final rel = ocfRelativePath(href);
      if (rel == null) continue; // absolute or `..`: not a chapter of this book
      final lower = rel.toLowerCase();
      if (!(mtype == 'application/xhtml+xml' ||
          mtype == 'text/html' ||
          lower.endsWith('.xhtml') ||
          lower.endsWith('.html') ||
          lower.endsWith('.htm'))) {
        continue;
      }
      // Resolve the archive entry once; null means the spine points at a file
      // the container does not hold, which must never fall back to the disk.
      spine.add((href: rel, entry: _access.entry(_opfDir, href)?.name));
    }

    final titles = _loadTitles(ncxHref, navHref);
    _chapters = [
      for (final chapter in spine)
        (
          href: chapter.href,
          title: titles[chapter.href] ?? _stem(chapter.href),
          entry: chapter.entry,
        ),
    ];
  }

  late final ArchiveAccess _access;

  late final String _opfPath;
  late final String _opfDir;
  late final List<({String href, String title, String? entry})> _chapters;

  /// (href relative to OPF dir, title) for each spine chapter.
  List<(String href, String title)> chapters() => [
    for (final chapter in _chapters) (chapter.href, chapter.title),
  ];

  /// Extract the whole epub into [destDir]; return the absolute OPF
  /// directory. Idempotent: skips extraction when a marker file exists.
  String extractTo(String destDir) {
    final dest = Directory(destDir)..createSync(recursive: true);
    final marker = File('${dest.path}/$_marker');
    if (!marker.existsSync()) {
      final root = ContainedRoot.resolve(dest.path);
      if (root == null) {
        throw FormatException('Cannot extract into: $destDir');
      }
      for (final file in _access.files) {
        final out = root.path(file.name);
        if (out == null) continue; // zip-slip: never write outside destDir
        final bytes = _access.bytes(file.name);
        if (bytes == null) continue; // over the size budget
        try {
          File(out).parent.createSync(recursive: true);
          File(out).writeAsBytesSync(bytes);
        } on FileSystemException {
          continue; // an entry that cannot be written does not fail the book
        }
      }
      marker.writeAsStringSync('ok');
    }
    final dir = dest.absolute.path;
    final opfDir = _opfDir.isEmpty ? dir : '$dir/$_opfDir';
    return Directory(opfDir).absolute.path;
  }

  /// Absolute filesystem path to chapter [index] after extraction.
  ///
  /// Throws [FormatException] when the spine entry is absent from the
  /// container or did not extract inside [destDir].
  String chapterFile(String destDir, int index) {
    _checkIndex(index);
    final chapter = _chapters[index];
    final entry = chapter.entry;
    if (entry == null) {
      throw FormatException('Missing chapter ${chapter.href} in $_opfPath');
    }
    extractTo(destDir);
    final root = ContainedRoot.resolve(destDir);
    final path = root?.file(entry);
    if (path == null) {
      throw FormatException('Missing chapter $entry in $_opfPath');
    }
    return path;
  }

  /// Raw XHTML of chapter [index] straight from the in-memory archive.
  ///
  /// Used for indexing: no extraction round trip, no temp files.
  String chapterSource(int index) {
    _checkIndex(index);
    final chapter = _chapters[index];
    final entry = chapter.entry;
    final text = entry == null ? null : _access.text(entry);
    if (text == null) {
      throw FormatException('Missing chapter ${chapter.href} in $_opfPath');
    }
    return text;
  }

  // -- internals -------------------------------------------------------------

  void _checkIndex(int index) {
    if (index < 0 || index >= _chapters.length) {
      throw RangeError.index(index, _chapters, 'chapter index out of range');
    }
  }

  Map<String, String> _loadTitles(String? ncxHref, String? navHref) {
    final titles = <String, String>{};
    if (ncxHref != null) titles.addAll(_titlesFromNcx(ncxHref));
    if (navHref != null && titles.isEmpty) {
      titles.addAll(_titlesFromNav(navHref));
    }
    return titles;
  }

  Map<String, String> _titlesFromNcx(String ncxHref) {
    final entry = _access.entry(_opfDir, ncxHref);
    final data = entry == null ? null : _access.text(entry.name);
    if (data == null) return {};
    final XmlDocument root;
    try {
      root = XmlDocument.parse(data);
    } on XmlException {
      return {};
    }
    final titles = <String, String>{};
    for (final point in root.descendants.whereType<XmlElement>()) {
      final pname = _localname(point);
      if (pname != 'navPoint' && pname != 'navTarget') continue;
      String? label;
      String? src;
      for (final child in point.descendants.whereType<XmlElement>()) {
        final name = _localname(child);
        if (name == 'text' && label == null) {
          label = child.innerText.trim();
        } else if (name == 'content' && src == null) {
          src = child.getAttribute('src');
        }
      }
      final href = src == null ? null : ocfRelativePath(src);
      if (label != null && label.isNotEmpty && href != null) {
        titles[href] = label;
      }
    }
    return titles;
  }

  Map<String, String> _titlesFromNav(String navHref) {
    final entry = _access.entry(_opfDir, navHref);
    final data = entry == null ? null : _access.text(entry.name);
    if (data == null) return {};
    final XmlDocument root;
    try {
      root = XmlDocument.parse(data);
    } on XmlException {
      return {};
    }
    final titles = <String, String>{};
    for (final elem in root.descendants.whereType<XmlElement>()) {
      if (_localname(elem) != 'a') continue;
      final href = elem.getAttribute('href');
      final text = elem.innerText.trim();
      final path = href == null ? null : ocfRelativePath(href);
      if (path != null && text.isNotEmpty) titles[path] = text;
    }
    return titles;
  }

  static String _stem(String href) {
    final slash = href.lastIndexOf('/');
    final base = slash < 0 ? href : href.substring(slash + 1);
    final dot = base.lastIndexOf('.');
    final stem = dot < 0 ? base : base.substring(0, dot);
    final cleaned = stem.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    return cleaned.isEmpty ? href : cleaned;
  }
}

/// Minimal EPUB (zip) parser — port of vellum/core/epub.py.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const _containerPath = 'META-INF/container.xml';
const _marker = '.extracted';

String _localname(XmlNode node) =>
    node is XmlElement ? node.name.local : '';

String _unquote(String href) {
  try {
    return Uri.decodeComponent(href);
  } on ArgumentError {
    return href;
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
    try {
      _archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw FormatException('Not a valid epub file: $path', e);
    }
    _entries = <String, ArchiveFile>{
      for (final file in _archive.files)
        if (file.isFile) file.name: file,
    };

    final containerData = _readEntry(_containerPath);
    if (containerData == null) {
      throw FormatException('Not an epub (missing $_containerPath): $path');
    }
    final XmlDocument container;
    try {
      container = XmlDocument.parse(containerData);
    } on XmlException catch (e) {
      throw FormatException('Corrupt container.xml in: $path', e);
    }

    String? opfPath;
    for (final elem in container.descendants.whereType<XmlElement>()) {
      if (_localname(elem) == 'rootfile') {
        opfPath = elem.getAttribute('full-path');
        break;
      }
    }
    if (opfPath == null || opfPath.isEmpty) {
      throw FormatException('No OPF rootfile in container: $path');
    }
    _opfPath = _unquote(opfPath);
    final slash = _opfPath.lastIndexOf('/');
    _opfDir = slash < 0 ? '' : _opfPath.substring(0, slash);

    final opfData = _readEntry(_opfPath);
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

    // Build spine list of XHTML hrefs (relative to OPF dir). Manifest hrefs
    // are URL-encoded per OCF, but ZIP entry names (and extracted files)
    // are not.
    final spine = <String>[];
    for (final idref in idrefs) {
      final entry = manifest[idref];
      if (entry == null) continue;
      final (href, mtype) = entry;
      final lower = href.toLowerCase();
      if (mtype == 'application/xhtml+xml' ||
          mtype == 'text/html' ||
          lower.endsWith('.xhtml') ||
          lower.endsWith('.html') ||
          lower.endsWith('.htm')) {
        spine.add(_unquote(href));
      }
    }

    final titles = _loadTitles(ncxHref, navHref);

    _chapters = [
      for (final href in spine) (href, titles[href] ?? _stem(href)),
    ];
  }

  late final Archive _archive;

  /// Archive entries by name: O(1) lookups instead of linear scans.
  late final Map<String, ArchiveFile> _entries;

  late final String _opfPath;
  late final String _opfDir;
  late final List<(String, String)> _chapters;

  /// (href relative to OPF dir, title) for each spine chapter.
  List<(String href, String title)> chapters() => List.of(_chapters);

  /// Extract the whole epub into [destDir]; return the absolute OPF
  /// directory. Idempotent: skips extraction when a marker file exists.
  String extractTo(String destDir) {
    Directory(destDir).createSync(recursive: true);
    final marker = '$destDir/$_marker';
    if (!File(marker).existsSync()) {
      final destRoot = Directory(destDir).absolute.path;
      for (final file in _archive.files) {
        if (!file.isFile) continue;
        final rel = _safeEntryPath(file.name);
        if (rel == null) continue; // skip unsafe entries (zip-slip)
        final out = File('$destDir/$rel');
        if (!out.absolute.path.startsWith('$destRoot/')) continue;
        out.parent.createSync(recursive: true);
        out.writeAsBytesSync(file.content as List<int>);
      }
      File(marker).writeAsStringSync('ok');
    }
    final opfDir = _opfDir.isEmpty ? destDir : '$destDir/$_opfDir';
    return Directory(opfDir).absolute.path;
  }

  /// Absolute filesystem path to chapter [index] after extraction.
  String chapterFile(String destDir, int index) {
    final (href, _) = _chapters[index];
    final opfDir = extractTo(destDir);
    return '$opfDir/${href.split('/').join('/')}';
  }

  /// Raw XHTML of chapter [index] straight from the in-memory archive.
  ///
  /// Used for indexing: no extraction round trip, no temp files.
  String chapterSource(int index) {
    if (index < 0 || index >= _chapters.length) {
      throw RangeError.index(index, _chapters, 'chapter index out of range');
    }
    final (href, _) = _chapters[index];
    final name = _opfDir.isEmpty ? href : '$_opfDir/$href';
    final entry = _entries[name] ?? _entries[href];
    if (entry == null) {
      throw FormatException('Missing chapter $name in $_opfPath');
    }
    return utf8.decode(entry.content as List<int>, allowMalformed: true);
  }

  // -- internals -------------------------------------------------------------

  /// Normalize a zip entry name posix-style; returns null when the entry is
  /// unsafe to extract (absolute, empty, or containing `..` segments).
  static String? _safeEntryPath(String name) {
    final posix = name.replaceAll('\\', '/');
    if (posix.startsWith('/') || RegExp(r'^[a-zA-Z]:/').hasMatch(posix)) {
      return null;
    }
    final segments = <String>[];
    for (final seg in posix.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      segments.add(seg);
    }
    if (segments.isEmpty) return null;
    return segments.join('/');
  }

  String? _readEntry(String name) {
    final entry = _entries[name];
    if (entry == null) return null;
    return utf8.decode(entry.content as List<int>, allowMalformed: true);
  }

  List<int>? _readEntryBytes(String name) {
    final entry = _entries[name];
    if (entry == null) return null;
    return entry.content as List<int>;
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
    final bytes = _readEntryBytes(_opfJoin(ncxHref));
    if (bytes == null) return {};
    final XmlDocument root;
    try {
      root = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
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
      if (label != null && label.isNotEmpty && src != null) {
        titles[_normalizeHref(src)] = label;
      }
    }
    return titles;
  }

  Map<String, String> _titlesFromNav(String navHref) {
    final bytes = _readEntryBytes(_opfJoin(navHref));
    if (bytes == null) return {};
    final XmlDocument root;
    try {
      root = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } on XmlException {
      return {};
    }
    final titles = <String, String>{};
    for (final elem in root.descendants.whereType<XmlElement>()) {
      if (_localname(elem) == 'a') {
        final href = elem.getAttribute('href');
        final text = elem.innerText.trim();
        if (href != null && href.isNotEmpty && text.isNotEmpty) {
          titles[_normalizeHref(href)] = text;
        }
      }
    }
    return titles;
  }

  String _opfJoin(String href) {
    href = _unquote(href);
    return _opfDir.isEmpty ? href : '$_opfDir/$href';
  }

  static String _normalizeHref(String href) {
    final hash = href.indexOf('#');
    return _unquote(hash < 0 ? href : href.substring(0, hash));
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

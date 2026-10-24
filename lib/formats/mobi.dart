/// Stdlib-style PalmDOC/MOBI extractor — port of vellum/core/mobi.py.
library;

import 'dart:convert';
import 'dart:io';

const _pdbHeaderLen = 78;
const _mobiHeaderOff = 16; // MOBI header starts after the 16-byte PalmDOC header
const _firstImageOff = 0x6C;
const _minMobiHeader = 0x70;

final _pagebreakRe = RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false);
final _headingSplitRe = RegExp(r'(?=<h[12][^>]*>)', caseSensitive: false);
final _headingRe = RegExp(r'<h[12][^>]*>(.*?)</h[12]>', caseSensitive: false, dotAll: true);
final _tagRe = RegExp(r'<[^>]+>');
final _recindexRe = RegExp(
  r'(<img\b[^>]*?)\brecindex="(\d+)"([^>]*)/?>',
  caseSensitive: false,
);

const _imageMagic = [
  ([0xFF, 0xD8, 0xFF], '.jpg'),
  ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], '.gif'), // GIF87a
  ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], '.gif'), // GIF89a
  ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], '.png'),
];

/// Standard PalmDOC LZ77 decompression.
List<int> _palmdocDecompress(List<int> data) {
  final out = <int>[];
  var i = 0;
  final n = data.length;
  while (i < n) {
    final c = data[i];
    i += 1;
    if (c == 0) {
      out.add(0);
    } else if (c <= 8) {
      out.addAll(data.sublist(i, i + c > n ? n : i + c));
      i += c;
    } else if (c <= 0x7F) {
      out.add(c);
    } else if (c <= 0xBF) {
      if (i >= n) break;
      final pair = (c << 8) | data[i];
      i += 1;
      final distance = pair >> 3;
      final length = (pair & 0x07) + 3;
      if (distance > out.length) break;
      for (var k = 0; k < length; k++) {
        out.add(out[out.length - distance]);
      }
    } else {
      out.add(0x20);
      out.add(c ^ 0x80);
    }
  }
  return out;
}

String? _imageExt(List<int> data) {
  for (final (magic, ext) in _imageMagic) {
    if (data.length >= magic.length) {
      var match = true;
      for (var i = 0; i < magic.length; i++) {
        if (data[i] != magic[i]) {
          match = false;
          break;
        }
      }
      if (match) return ext;
    }
  }
  return null;
}

int _be16(List<int> d, int off) => (d[off] << 8) | d[off + 1];
int _be32(List<int> d, int off) =>
    (d[off] << 24) | (d[off + 1] << 16) | (d[off + 2] << 8) | d[off + 3];

class MobiBook {
  /// Parse a MOBI/PalmDOC file into HTML sections plus image records.
  MobiBook(String path) {
    final List<int> data;
    try {
      data = File(path).readAsBytesSync();
    } on IOException catch (e) {
      throw FormatException('cannot read MOBI file: $path', e);
    }
    _parse(data);
  }

  Map<int, String> _imageFiles = {};
  String _imageDir = '';
  late final List<List<int>> _records;
  late final int _firstImage;
  late final String _html;
  late final List<String> _chunks;
  late final List<(int, String)> _sections;

  // -- parsing ---------------------------------------------------------------

  void _parse(List<int> data) {
    if (data.length < _pdbHeaderLen + 8 ||
        String.fromCharCodes(data.sublist(60, 68)) != 'BOOKMOBI') {
      throw const FormatException('not a MOBI file');
    }
    final numRecords = _be16(data, 76);
    if (numRecords < 1 || data.length < _pdbHeaderLen + 8 * numRecords) {
      throw const FormatException('corrupt MOBI record table');
    }
    final offsets = <int>[];
    for (var i = 0; i < numRecords; i++) {
      offsets.add(_be32(data, _pdbHeaderLen + i * 8));
    }
    final records = <List<int>>[];
    for (var i = 0; i < offsets.length; i++) {
      final off = offsets[i];
      final end = i + 1 < offsets.length ? offsets[i + 1] : data.length;
      if (off > data.length || end > data.length || end < off) {
        throw const FormatException('corrupt MOBI record offsets');
      }
      records.add(data.sublist(off, end));
    }

    final rec0 = records[0];
    if (rec0.length < _mobiHeaderOff + _minMobiHeader) {
      throw const FormatException('corrupt MOBI record 0');
    }
    final compression = _be16(rec0, 0);
    if (compression != 1 && compression != 2) {
      throw FormatException('unsupported PalmDOC compression: $compression');
    }
    final textLength = _be32(rec0, 4);
    final textRecordCount = _be16(rec0, 8);
    final mobi = rec0.sublist(_mobiHeaderOff);
    if (String.fromCharCodes(mobi.sublist(0, 4)) != 'MOBI') {
      throw const FormatException('missing MOBI header');
    }
    final encoding = _be32(mobi, 0x0C);
    final firstImage = _be32(mobi, _firstImageOff);

    _records = records;
    _firstImage = firstImage < numRecords ? firstImage : numRecords;

    final chunks = <int>[];
    final upper = 1 + textRecordCount > records.length
        ? records.length
        : 1 + textRecordCount;
    for (var i = 1; i < upper; i++) {
      chunks.addAll(
        compression == 2 ? _palmdocDecompress(records[i]) : records[i],
      );
    }
    final text = chunks.length > textLength ? chunks.sublist(0, textLength) : chunks;
    if (encoding == 0 || encoding == 65001) {
      _html = utf8.decode(text, allowMalformed: true);
    } else {
      // cp1252 (and other Windows code pages): approximate via latin1,
      // mapping the cp1252 high range back to proper code points.
      _html = _decodeCp1252(text);
    }
    _sections = _splitSections();
  }

  static const _cp1252High = {
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
    0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
    0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
    0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
    0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
    0x9E: 0x017E, 0x9F: 0x0178,
  };

  static String _decodeCp1252(List<int> bytes) {
    final codes = [
      for (final b in bytes) _cp1252High[b] ?? b,
    ];
    return String.fromCharCodes(codes);
  }

  List<(int, String)> _splitSections() {
    final html = _html;
    var bounds = <int>[0];
    final breaks = _pagebreakRe.allMatches(html).toList();
    if (breaks.isNotEmpty) {
      bounds.addAll(breaks.map((m) => m.end));
    } else {
      bounds.addAll(
        _headingSplitRe.allMatches(html).map((m) => m.start).where((s) => s > 0),
      );
    }
    bounds = bounds.toSet().toList()..sort();
    final sections = <(int, String, String)>[];
    for (var pos = 0; pos < bounds.length; pos++) {
      final start = bounds[pos];
      final end = pos + 1 < bounds.length ? bounds[pos + 1] : html.length;
      final chunk = html.substring(start, end);
      if (chunk.replaceAll(_tagRe, '').trim().isEmpty) continue;
      final heading = _headingRe.firstMatch(chunk);
      var title = heading != null
          ? heading.group(1)!.replaceAll(_tagRe, '').trim()
          : '';
      if (title.isEmpty) title = 'Section ${sections.length + 1}';
      sections.add((start, title, chunk));
    }
    _chunks = [for (final s in sections) s.$3];
    return [for (final s in sections) (s.$1, s.$2)];
  }

  // -- public API --------------------------------------------------------------

  /// (record offset, title) for each section.
  List<(int offset, String title)> sections() => List.of(_sections);

  /// Raw HTML chunk for section [index], without extracting images.
  ///
  /// Indexing only needs the text; this avoids creating a temp directory.
  String sectionSource(int index) {
    if (index < 0 || index >= _chunks.length) {
      throw RangeError.index(index, _chunks, 'section index out of range');
    }
    return _chunks[index];
  }

  /// Full HTML document for section [index] with image refs rewritten.
  String sectionHtml(int index) {
    if (index < 0 || index >= _chunks.length) {
      throw RangeError.index(index, _chunks, 'section index out of range');
    }
    if (_imageDir.isEmpty) {
      extractTo(Directory.systemTemp
          .createTempSync('vellum-mobi-')
          .path);
    }
    final body = _chunks[index].replaceAllMapped(_recindexRe, _rewriteImg);
    return '<!DOCTYPE html>\n'
        '<html><head><meta charset="utf-8" /></head>'
        '<body>$body</body></html>';
  }

  String _rewriteImg(Match match) {
    final pre = match.group(1)!;
    final recindex = int.parse(match.group(2)!);
    var attrs = match.group(3)!.trim();
    // MOBI recindex is 1-based and relative to the first image record.
    final record = _firstImage + recindex - 1;
    final filename = _imageFiles[record];
    if (attrs.endsWith('/')) attrs = attrs.substring(0, attrs.length - 1).trimRight();
    var src = '';
    if (filename != null) {
      final uri = Uri.file('$_imageDir/$filename');
      src = ' src="$uri"';
    }
    final tail = attrs.isNotEmpty ? ' $attrs' : '';
    return '${pre.trimRight()}$src$tail />';
  }

  /// Extract image records into [destDir] (idempotent); returns the dir.
  String extractTo(String destDir) {
    destDir = Directory(destDir).absolute.path;
    Directory(destDir).createSync(recursive: true);
    final marker = '$destDir/.extracted';
    _imageDir = destDir;
    if (File(marker).existsSync()) {
      _imageFiles = {
        for (final name in Directory(destDir)
            .listSync()
            .map((e) => e.uri.pathSegments.last)
            .where((n) => n.startsWith('img-') && n.contains('.')))
          // Skip foreign img-*.* files with non-numeric stems.
          if (int.tryParse(name.substring(4, name.lastIndexOf('.')))
              case final index?)
            index: name,
      };
      return destDir;
    }
    _imageFiles = {};
    for (var recindex = _firstImage; recindex < _records.length; recindex++) {
      final ext = _imageExt(_records[recindex]);
      if (ext == null) continue;
      final name = 'img-$recindex$ext';
      File('$destDir/$name').writeAsBytesSync(_records[recindex]);
      _imageFiles[recindex] = name;
    }
    File(marker).writeAsStringSync('ok\n');
    return destDir;
  }
}

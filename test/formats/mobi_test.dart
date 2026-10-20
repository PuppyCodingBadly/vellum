/// Tests for vellum formats/mobi.dart (mirrors tests/test_mobi.py).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vellum/formats/mobi.dart';
import 'package:xml/xml.dart';

final _text = '<h1>Alpha</h1><p>one</p>'
    '<mbp:pagebreak/>'
    '<h1>Beta</h1><p>two</p><img recindex="1"/>';
final _gif = [
  ...'GIF89a'.codeUnits,
  0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
  ...List.filled(16, 0),
];

String _makeMobi(String path, {List<int>? text, int encoding = 65001}) {
  text ??= utf8.encode(_text);
  final half = text.length ~/ 2;
  final rec1 = text.sublist(0, half);
  final rec2 = text.sublist(half);

  // Record 0: PalmDOC header (16 bytes) + MOBI header.
  final palmdoc = ByteData(16)
    ..setUint16(0, 1) // compression = none
    ..setUint16(2, 0)
    ..setUint32(4, text.length)
    ..setUint16(8, 2) // text record count
    ..setUint16(10, 4096)
    ..setUint16(12, 0)
    ..setUint16(14, 0);
  final mobi = ByteData(0x70);
  for (var i = 0; i < 4; i++) {
    mobi.setUint8(i, 'MOBI'.codeUnits[i]);
  }
  mobi
    ..setUint32(4, 0xE8) // header length
    ..setUint32(0x0C, encoding) // text encoding
    ..setUint32(0x50, 3) // first non-book index
    ..setUint32(0x6C, 3); // first image index
  final rec0 = [...palmdoc.buffer.asUint8List(), ...mobi.buffer.asUint8List()];

  final records = [rec0, rec1, rec2, _gif];
  final num = records.length;

  // PDB header.
  final header = ByteData(78);
  final name = 'TestBook'.codeUnits;
  for (var i = 0; i < name.length; i++) {
    header.setUint8(i, name[i]);
  }
  for (var i = 0; i < 8; i++) {
    header.setUint8(60 + i, 'BOOKMOBI'.codeUnits[i]);
  }
  header.setUint16(76, num);

  final tableSize = 8 * num;
  var offset = 78 + tableSize;
  final table = BytesBuilder();
  for (final rec in records) {
    final entry = ByteData(8)
      ..setUint32(0, offset)
      ..setUint32(4, 0);
    table.add(entry.buffer.asUint8List());
    offset += rec.length;
  }

  File(path).writeAsBytesSync([
    ...header.buffer.asUint8List(),
    ...table.toBytes(),
    for (final rec in records) ...rec,
  ]);
  return path;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mobi-test-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('sections split on pagebreak with titles', () {
    final mobi = MobiBook(_makeMobi('${tmp.path}/book.mobi'));
    final sections = mobi.sections();
    expect(sections.length, 2);
    expect([for (final s in sections) s.$2], ['Alpha', 'Beta']);
    expect(sections[1].$1, greaterThan(sections[0].$1));
  });

  test('sectionHtml contents and img rewrite', () {
    final mobi = MobiBook(_makeMobi('${tmp.path}/book.mobi'));
    final dest = '${tmp.path}/extract';
    mobi.extractTo(dest);

    final html0 = mobi.sectionHtml(0);
    expect(html0, contains('Alpha'));
    expect(html0, contains('one'));
    expect(html0.startsWith('<!DOCTYPE html'), isTrue);

    final html1 = mobi.sectionHtml(1);
    expect(html1, contains('Beta'));
    expect(html1, isNot(contains('recindex="')));
    expect(html1, contains('img-3.gif'));
    XmlDocument.parse(html1); // generated markup must be well-formed
  });

  test('text encoding cp1252', () {
    final text = latin1.encode('<h1>Café</h1><p>one</p>'); // é = 0xE9 cp1252
    final mobi = MobiBook(
        _makeMobi('${tmp.path}/cp1252.mobi', text: text, encoding: 1252));
    expect(mobi.sectionHtml(0), contains('Café'));
  });

  test('extractTo is idempotent', () {
    final mobi = MobiBook(_makeMobi('${tmp.path}/book.mobi'));
    final dest = '${tmp.path}/extract';

    final out = mobi.extractTo(dest);
    expect(Directory(out).absolute.path, Directory(dest).absolute.path);
    final gifPath = '$out/img-3.gif';
    expect(File(gifPath).existsSync(), isTrue);
    expect(File(gifPath).readAsBytesSync(), _gif);

    // Second call skips re-extraction: remove the file, it must stay removed.
    File(gifPath).deleteSync();
    expect(mobi.extractTo(dest), out);
    expect(File(gifPath).existsSync(), isFalse);
    // Images mapping rebuilt from directory listing.
    expect(mobi.sectionHtml(1), isNot(contains('img-3.gif')));
  });

  test('garbage file throws FormatException', () {
    final bad = File('${tmp.path}/garbage.mobi')
      ..writeAsBytesSync('this is not a mobi at all'.codeUnits);
    expect(() => MobiBook(bad.path), throwsFormatException);
  });
}

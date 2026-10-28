/// Fixtures shared by the widget tests.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:vellum/plugins/sidecar_client.dart';

/// A sidecar that never spawns a process, so widget tests leave no timers.
class EmptySidecar extends SidecarClient {
  @override
  Future<LoadedPlugins> loadAll(String pluginDir) async =>
      const LoadedPlugins();

  @override
  Future<LoadedPlugins> loaded(String pluginDir) async => const LoadedPlugins();
}

/// Writes a minimal three-chapter EPUB to [path] and returns [path].
String buildTestEpub(String path) {
  final archive = Archive();
  archive.addFile(ArchiveFile.string('mimetype', 'application/epub+zip'));
  archive.addFile(
    ArchiveFile.string(
      'META-INF/container.xml',
      '<?xml version="1.0"?>'
          '<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles></container>',
    ),
  );
  archive.addFile(
    ArchiveFile.string(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="utf-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
          'unique-identifier="bookid">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>The Smoke Test Book</dc:title>'
          '<dc:creator>Test Author</dc:creator>'
          '<dc:identifier id="bookid">urn:isbn:9780441013593</dc:identifier>'
          '<dc:language>en</dc:language></metadata>'
          '<manifest>'
          '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
          'properties="nav"/>'
          '<item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c3" href="ch3.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine>'
          '<itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>'
          '</spine></package>',
    ),
  );
  archive.addFile(
    ArchiveFile.string(
      'OEBPS/nav.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol>'
          '<li><a href="ch1.xhtml">Chapter 1</a></li>'
          '<li><a href="ch2.xhtml">Chapter 2</a></li>'
          '<li><a href="ch3.xhtml">Chapter 3</a></li>'
          '</ol></nav></body></html>',
    ),
  );
  for (var i = 1; i <= 3; i++) {
    archive.addFile(
      ArchiveFile.string(
        'OEBPS/ch$i.xhtml',
        '<html><body><h1>Chapter $i</h1>'
            '<p>The moonstone lantern glowed over harbour number $i.</p>'
            '<p>A distinctive phrase number $i appears here.</p>'
            '</body></html>',
      ),
    );
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive));
  return path;
}

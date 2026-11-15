/// Download helpers for the store view, ported from
/// `ui/store_view.py`'s download flow.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../metadata/universal.dart' show readBodyCapped;

/// Largest download accepted from a store, in bytes.
const int maxDownloadBytes = 512 * 1024 * 1024;

/// Deadline between body chunks; a stalled transfer is abandoned.
const Duration downloadIdleTimeout = Duration(seconds: 120);

/// Build a safe download file name from a book [title] and format [ext].
///
/// Mirrors `_safe_filename` + `_download_file` from `store_view.py`:
/// characters outside `[\w\-. ]` are stripped, the stem is clamped to 80
/// characters, the extension is lower-cased and reduced to `[a-z0-9]`
/// (falling back to `'epub'`), and `name (N).ext` dedup is applied against
/// the [exists] callback (which should report whether a candidate name
/// already exists in the destination directory).
String sanitizeDownloadFileName(
  String title,
  String ext, {
  bool Function(String candidate)? exists,
}) {
  var stem = title.replaceAll(RegExp(r'[^\w\-. ]+', unicode: true), '');
  // strip leading/trailing spaces and dots, like Python's .strip(" .")
  stem = stem.replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80);
  if (stem.isEmpty) stem = 'book';

  var suffix = ext.split(',').first.trim().toLowerCase();
  suffix = suffix.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (suffix.isEmpty) suffix = 'epub';

  var candidate = '$stem.$suffix';
  if (exists == null) return candidate;
  var counter = 1;
  while (exists(candidate)) {
    candidate = '$stem ($counter).$suffix';
    counter++;
  }
  return candidate;
}

/// Downloads [url] into [directory] and returns the published file.
///
/// The body streams into a `.part` sibling, so a truncated, oversized or
/// timed-out transfer never leaves a file at the final name: the partial is
/// deleted and the error reaches the caller.  The `.part` name is claimed with
/// an exclusive create, so two downloads of the same title cannot write the
/// same file.
Future<File> downloadBook({
  required String url,
  required String title,
  required String formats,
  required String directory,
  http.Client? client,
}) async {
  final target = await _reserveTarget(directory, title, formats);
  final httpClient = client ?? http.Client();
  var published = false;
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'download failed with status ${response.statusCode}',
        uri: request.url,
      );
    }
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (_isMarkup(contentType)) {
      throw HttpException(
        'download served $contentType instead of an ebook',
        uri: request.url,
      );
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxDownloadBytes) {
      throw HttpException(
        'download is larger than $maxDownloadBytes bytes',
        uri: request.url,
      );
    }

    final sink = target.part.openWrite();
    try {
      final read = await readBodyCapped(
        response,
        onChunk: sink.add,
        maxBytes: maxDownloadBytes,
        idleTimeout: downloadIdleTimeout,
      );
      if (read.length == 0) throw const FormatException('download was empty');
      if (read.truncated) {
        throw FormatException(
          'download is larger than $maxDownloadBytes bytes',
        );
      }
      await sink.flush();
    } catch (_) {
      // The transfer failed; close quietly so the sink cannot mask it.
      await sink.close().catchError((Object _) {});
      rethrow;
    }
    await sink.close();

    await target.part.rename(target.file.path);
    published = true;
    return target.file;
  } finally {
    if (client == null) httpClient.close();
    if (!published) {
      try {
        await target.part.delete();
      } on FileSystemException {
        // Already gone (the write path may have cleaned up).
      }
    }
  }
}

/// A `.part` file this download owns and the final path it publishes to.
class _DownloadTarget {
  const _DownloadTarget(this.part, this.file);

  final File part;
  final File file;
}

/// Claims a free `stem[ (N)].ext` in [directory] by creating its `.part`
/// sibling exclusively; the claim is what makes concurrent downloads of the
/// same title pick different files.
Future<_DownloadTarget> _reserveTarget(
  String directory,
  String title,
  String formats,
) async {
  await Directory(directory).create(recursive: true);
  bool taken(String candidate) =>
      File(p.join(directory, candidate)).existsSync() ||
      File(p.join(directory, '$candidate.part')).existsSync();
  final base = sanitizeDownloadFileName(title, formats, exists: taken);
  final extension = p.extension(base);
  final stem = base.substring(0, base.length - extension.length);
  for (var counter = 0; counter < 10000; counter++) {
    final name = counter == 0 ? base : '$stem ($counter)$extension';
    final file = File(p.join(directory, name));
    if (await file.exists()) continue;
    final part = File('${file.path}.part');
    try {
      await part.create(exclusive: true);
    } on FileSystemException {
      continue; // Another download claimed this name first.
    }
    return _DownloadTarget(part, file);
  }
  throw FileSystemException('no free download name in $directory', directory);
}

/// Whether [contentType] is a web page or API document rather than a book.
bool _isMarkup(String contentType) =>
    contentType.startsWith('text/') ||
    contentType.contains('html') ||
    contentType.contains('json') ||
    contentType.contains('xml');

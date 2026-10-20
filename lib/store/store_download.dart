/// Download helpers for the store view, ported from
/// `ui/store_view.py`'s download flow.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

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

/// Stream [url] to [destPath] in 64 KiB chunks with a 120 s timeout.
///
/// Mirrors `_download_file`'s `requests.get(..., stream=True)` loop.
/// Returns [destPath].  Throws on a non-2xx status or network failure.
Future<String> downloadToFile(
  String url,
  String destPath, {
  http.Client? client,
}) async {
  final ownsClient = client == null;
  final httpClient = client ?? http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await httpClient
        .send(request)
        .timeout(const Duration(seconds: 120));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
          'download failed with status ${response.statusCode}',
          uri: Uri.parse(url));
    }
    final file = File(destPath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      await response.stream
          .timeout(const Duration(seconds: 120))
          .forEach(sink.add);
      await sink.flush();
    } finally {
      await sink.close();
    }
    return destPath;
  } finally {
    if (ownsClient) httpClient.close();
  }
}

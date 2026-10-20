/// Cover thumbnail caching.
///
/// Ports `vellum/core/covers.py` using package:image.
library;

// Mirrors the Python constants (covers.py) verbatim.
// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// Maximum thumbnail edge dimensions.
const int THUMB_MAX_WIDTH = 320;
const int THUMB_MAX_HEIGHT = 480;

/// Covers larger than this many bytes are never thumbnailed.
const int MAX_COVER_BYTES = 25 * 1024 * 1024;

/// Covers with more pixels than this are never thumbnailed.
const int MAX_COVER_PIXELS = 80000000;

/// Best-effort `os.path.realpath` equivalent: resolves symlinks when the
/// file exists, otherwise falls back to the absolute path.
String _realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    return File(path).absolute.path;
  }
}

/// Deterministic cache path for the thumbnail of [coverPath]:
/// `<dataDir>/covers/thumbs/<bookId>-<sha1(realpath)[:12]>.png`.
String thumbCachePath(String dataDir, int bookId, String coverPath) {
  final digest = sha1.convert(utf8.encode(_realpath(coverPath))).toString();
  return '$dataDir/covers/thumbs/$bookId-${digest.substring(0, 12)}.png';
}

/// Returns a thumbnail path for [coverPath], generating it if needed.
///
/// Falls back to the original [coverPath] on: missing/empty path, any
/// error, oversized file or pixel count, or decode failure. A fresh cached
/// thumbnail (mtime >= cover mtime) is returned directly.
String thumbPath(String dataDir, int bookId, String coverPath) {
  try {
    if (coverPath.isEmpty) return coverPath;
    final cover = File(coverPath);
    if (!cover.existsSync()) return coverPath;
    final thumbFile = File(thumbCachePath(dataDir, bookId, coverPath));
    final coverMtime = cover.lastModifiedSync();
    if (thumbFile.existsSync() &&
        !thumbFile.lastModifiedSync().isBefore(coverMtime)) {
      return thumbFile.path;
    }
    if (cover.lengthSync() > MAX_COVER_BYTES) return coverPath;
    final bytes = cover.readAsBytesSync();
    final image = img.decodeImage(bytes);
    if (image == null) return coverPath;
    if (image.width <= 0 ||
        image.height <= 0 ||
        image.width * image.height > MAX_COVER_PIXELS) {
      return coverPath;
    }
    final scale = math.min(
      math.min(THUMB_MAX_WIDTH / image.width, THUMB_MAX_HEIGHT / image.height),
      1.0,
    );
    final w = math.max(1, (image.width * scale).round());
    final h = math.max(1, (image.height * scale).round());
    final thumb = img.copyResize(
      image,
      width: w,
      height: h,
      interpolation: img.Interpolation.linear,
    );
    thumbFile.parent.createSync(recursive: true);
    thumbFile.writeAsBytesSync(img.encodePng(thumb));
    return thumbFile.path;
  } catch (_) {
    return coverPath;
  }
}

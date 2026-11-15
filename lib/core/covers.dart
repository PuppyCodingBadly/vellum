/// Cover artwork: storing downloaded covers and caching their thumbnails.
///
/// Ports `vellum/core/covers.py` using package:image.
library;

// Mirrors the Python constants (covers.py) verbatim.
// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// Maximum thumbnail edge dimensions.
const int THUMB_MAX_WIDTH = 320;
const int THUMB_MAX_HEIGHT = 480;

/// Covers larger than this many bytes are never thumbnailed.
const int MAX_COVER_BYTES = 25 * 1024 * 1024;

/// Covers with more pixels than this are never thumbnailed.
const int MAX_COVER_PIXELS = 80000000;

/// Trailing bytes of every complete PNG (an empty IEND chunk with its CRC).
const List<int> _pngEnd = [
  0,
  0,
  0,
  0,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

/// Best-effort `os.path.realpath` equivalent: resolves symlinks when the
/// file exists, otherwise falls back to the absolute path.
String _realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    return File(path).absolute.path;
  }
}

/// Identity of the cover bytes a thumbnail was made from: source mtime and
/// size. Rewriting a cover in place changes both, so the derived thumb path
/// changes and `FileImage` cannot serve the old bitmap from its path-keyed
/// cache.
String _sourceVersion(String coverPath) {
  try {
    final stat = File(coverPath).statSync();
    return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
  } catch (_) {
    return '0:0';
  }
}

/// Deterministic cache path for the thumbnail of [coverPath]:
/// `<dataDir>/covers/thumbs/<bookId>-<sha1(realpath + mtime + size)[:12]>.png`.
String thumbCachePath(String dataDir, int bookId, String coverPath) {
  final identity = '${_realpath(coverPath)}|${_sourceVersion(coverPath)}';
  final digest = sha1.convert(utf8.encode(identity)).toString();
  return '$dataDir/covers/thumbs/$bookId-${digest.substring(0, 12)}.png';
}

/// A cached thumbnail is served only when it is a complete PNG. A truncated
/// file (a legacy partial write) lacks the IEND trailer.
bool _isCompletePng(File file) {
  try {
    final bytes = file.readAsBytesSync();
    if (bytes.length < _pngEnd.length) return false;
    final tail = bytes.length - _pngEnd.length;
    for (var i = 0; i < _pngEnd.length; i++) {
      if (bytes[tail + i] != _pngEnd[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// True when [bytes] declares dimensions within [MAX_COVER_PIXELS].
///
/// `startDecode` reads only the container header, so an absurdly large raster
/// (a tiny compressed file declaring 20000×20000) is rejected before any
/// pixel buffer is allocated.
bool _fitsPixelBudget(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) return false;
  final info = decoder.startDecode(bytes);
  if (info == null) return false;
  return info.width > 0 &&
      info.height > 0 &&
      info.width * info.height <= MAX_COVER_PIXELS;
}

/// Decodes [bytes] with the thumbnail pixel cap applied to the decoder, so a
/// header the preflight cannot understand still cannot allocate past the cap.
img.Image? _decodeWithinBudget(Uint8List bytes) {
  final previous = img.Decoder.defaultMaxPixels;
  img.Decoder.defaultMaxPixels = MAX_COVER_PIXELS;
  try {
    return img.decodeImage(bytes);
  } finally {
    img.Decoder.defaultMaxPixels = previous;
  }
}

/// Writes [bytes] to [target] through a sibling temp file and a rename, so a
/// crash mid-write can never leave a partial thumbnail at the cache path.
void _writeAtomically(File target, List<int> bytes) {
  target.parent.createSync(recursive: true);
  final temp = File(
    '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(target.path);
  } finally {
    if (temp.existsSync()) {
      try {
        temp.deleteSync();
      } catch (_) {
        // Best effort: the rename already succeeded in the common case.
      }
    }
  }
}

/// Returns a thumbnail path for [coverPath], generating it if needed.
///
/// Falls back to the original [coverPath] on: missing/empty path, any
/// error, oversized file or pixel count, or decode failure. A cached thumb
/// is keyed by the cover's path, mtime and size, so it is reused only while
/// those bytes are unchanged.
String thumbPath(String dataDir, int bookId, String coverPath) {
  try {
    if (coverPath.isEmpty) return coverPath;
    final cover = File(coverPath);
    if (!cover.existsSync()) return coverPath;
    final thumbFile = File(thumbCachePath(dataDir, bookId, coverPath));
    if (_isCompletePng(thumbFile)) return thumbFile.path;
    if (cover.lengthSync() > MAX_COVER_BYTES) return coverPath;
    final bytes = cover.readAsBytesSync();
    if (!_fitsPixelBudget(bytes)) return coverPath;
    final image = _decodeWithinBudget(bytes);
    if (image == null || image.width <= 0 || image.height <= 0) {
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
    _writeAtomically(thumbFile, img.encodePng(thumb));
    return thumbFile.path;
  } catch (_) {
    return coverPath;
  }
}

/// The cover could not be stored; the book row was not touched.
///
/// Callers treat this as a cover problem rather than a metadata one: nothing
/// was saved, so they can still store the metadata without artwork.
class CoverWriteException implements Exception {
  const CoverWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

const List<int> _jpegMagic = [0xFF, 0xD8, 0xFF];
const List<int> _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const List<int> _gifMagic = [0x47, 0x49, 0x46, 0x38]; // GIF87a and GIF89a
const List<int> _riffMagic = [0x52, 0x49, 0x46, 0x46];
const List<int> _webpMagic = [0x57, 0x45, 0x42, 0x50]; // WEBP at offset 8

/// True when [bytes] start with [magic] at offset [at].
bool _hasMagic(Uint8List bytes, List<int> magic, [int at = 0]) {
  if (bytes.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[at + i] != magic[i]) return false;
  }
  return true;
}

/// The extension of [bytes] when their container is one this writer stores
/// unchanged, otherwise null.
String? _coverExtension(Uint8List bytes) {
  if (_hasMagic(bytes, _jpegMagic)) return '.jpg';
  if (_hasMagic(bytes, _pngMagic)) return '.png';
  if (_hasMagic(bytes, _gifMagic)) return '.gif';
  if (_hasMagic(bytes, _riffMagic) && _hasMagic(bytes, _webpMagic, 8)) {
    return '.webp';
  }
  return null;
}

/// The extension and bytes a cover file gets for [bytes].
///
/// A known container keeps its own bytes and extension, so a JPEG is never
/// re-encoded. Anything else is decoded and re-encoded as PNG, so the stored
/// file never lies about its format; bytes no decoder accepts are rejected
/// instead of being written under an arbitrary extension.
(String, Uint8List) _coverFile(Uint8List bytes) {
  final extension = _coverExtension(bytes);
  if (extension != null) return (extension, bytes);
  final image = _decodeWithinBudget(bytes);
  if (image == null) {
    throw const CoverWriteException('cover data is not a decodable image');
  }
  return ('.png', img.encodePng(image));
}

/// Stores [bytes] as the cover of [bookId] and saves the row naming it.
///
/// [saveBook] persists the row with the cover path it receives. The bytes are
/// staged under a temp name in the covers directory first, so a [saveBook]
/// that throws leaves the previous artwork untouched and no partial file
/// behind; only after the save succeeds is the staged file renamed over the
/// old cover. Covers named `<bookId>.<ext>` left by an earlier format are then
/// deleted. Those files are the only ones this writer owns, which is why a
/// generated cover (`generated-<bookId>.png`) and artwork imported from
/// elsewhere are never deleted.
///
/// Throws [CoverWriteException] when the artwork is not an image or cannot be
/// staged, in which case [saveBook] was not called. A throwing [saveBook]
/// propagates unchanged.
Future<void> replaceCover({
  required String dataDir,
  required int bookId,
  required Uint8List bytes,
  required void Function(String coverPath) saveBook,
}) async {
  final (extension, stored) = _coverFile(bytes);
  final coversDir = Directory('$dataDir/covers');
  final target = File('${coversDir.path}/$bookId$extension');
  final staged = File(
    '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await coversDir.create(recursive: true);
    await staged.writeAsBytes(stored, flush: true);
  } on FileSystemException catch (error) {
    await _deleteQuietly(staged);
    throw CoverWriteException('could not store the cover: $error');
  }
  try {
    saveBook(target.path);
    await staged.rename(target.path);
  } catch (_) {
    await _deleteQuietly(staged);
    rethrow;
  }
  await _deleteReplacedCovers(coversDir, bookId, target.path);
}

/// Deletes the `<bookId>.<ext>` covers that [keep] replaces.
///
/// Direct children of [coversDir] named `<bookId>.…` are the files this writer
/// has stored for the book over time, plus temps a crash left behind.
/// Thumbnails live in a subdirectory and generated covers
/// (`generated-<bookId>.png`) do not match the prefix, so both survive.
Future<void> _deleteReplacedCovers(
  Directory coversDir,
  int bookId,
  String keep,
) async {
  final prefix = '$bookId.';
  try {
    await for (final entry in coversDir.list()) {
      if (entry is! File || entry.path == keep) continue;
      if (!entry.uri.pathSegments.last.startsWith(prefix)) continue;
      await _deleteQuietly(entry);
    }
  } on FileSystemException {
    // A stale cover is harmless: the row already names the new file.
  }
}

/// Deletes [file] if it exists, ignoring failures.
Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Best effort: the caller is already reporting why the file is stale.
  }
}

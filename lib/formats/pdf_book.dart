/// PDF reading via PDFium — port of vellum/core/pdfbook.py.
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_dart/pdfium_dart.dart';

/// Default rasterization scale (1.0 = PDF points at 72 dpi).
const defaultScale = 1.75;

/// Typed failure from PDFium rasterization, safe to show to the reader.
class PdfRenderException implements Exception {
  const PdfRenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads a PDF document and rasterizes pages to PNG with PDFium.
///
/// The document is opened synchronously; use [renderPage] for pixels and
/// [pageCount] / [titleAt] for navigation metadata.
class PdfBook {
  /// Open a PDF and render pages to PNG bytes.
  ///
  /// Validates the `%PDF-` header and loads the document through PDFium.
  /// Throws [FormatException] when [path] is unreadable or not a PDF.
  PdfBook(String path) : _path = path {
    final List<int> head;
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      head = file.readSync(5);
    } on FileSystemException catch (e) {
      throw FormatException('not a readable PDF: $path', e);
    } finally {
      file?.closeSync();
    }
    const magic = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
    if (head.length < magic.length) {
      throw FormatException('not a readable PDF: $path');
    }
    for (var i = 0; i < magic.length; i++) {
      if (head[i] != magic[i]) {
        throw FormatException('not a readable PDF: $path');
      }
    }
    _doc = _loadDocument(_library, path);
    if (_library.FPDF_GetPageCount(_doc) < 1) {
      _library.FPDF_CloseDocument(_doc);
      throw FormatException('not a readable PDF: $path');
    }
  }

  final String _path;
  late final FPDF_DOCUMENT _doc;
  bool _closed = false;

  /// Largest bitmap rendered in one call: 100 MP (≈400 MB of BGRA pixels).
  ///
  /// Crafted MediaBoxes and deep zooms must fail before allocating, not take
  /// the process down with an OOM.
  static const int maxRasterPixels = 100 * 1000 * 1000;

  void _ensureOpen() {
    if (_closed) throw StateError('PDF document is closed: $_path');
  }

  /// Close the PDFium document, releasing native resources.
  ///
  /// Safe to call more than once; later calls are no-ops.
  void close() {
    if (_closed) return;
    _closed = true;
    _library.FPDF_CloseDocument(_doc);
  }

  /// Releases PDFium's process-global resources.
  ///
  /// Only call once the isolate owning this library is finished with every
  /// document (the reader worker calls it just before exiting).
  static void shutdownLibrary() {
    final pdfium = _pdfiumCache;
    if (pdfium == null) return;
    _pdfiumCache = null;
    pdfium.FPDF_DestroyLibrary();
  }

  /// Bitmap size for a page of [widthPoints]×[heightPoints] at [scale].
  ///
  /// Clamps each dimension to 1 px, then throws [PdfRenderException] when the
  /// pixel count would exceed [maxRasterPixels] — before any allocation.
  static ({int width, int height}) rasterSize(
    double widthPoints,
    double heightPoints,
    double scale,
  ) {
    if (!scale.isFinite || scale <= 0) {
      throw const PdfRenderException('invalid PDF render scale');
    }
    if (!widthPoints.isFinite || !heightPoints.isFinite) {
      throw const PdfRenderException('PDF page has an invalid size');
    }
    final width =
        (widthPoints * scale).round().clamp(1, 1 << 30);
    final height =
        (heightPoints * scale).round().clamp(1, 1 << 30);
    if (width * height > maxRasterPixels) {
      throw const PdfRenderException(
        'PDF page is too large to render at this zoom',
      );
    }
    return (width: width, height: height);
  }

  static PDFium? _pdfiumCache;

  /// Load and initialize PDFium once per process.
  ///
  /// Honors `PDFIUM_PATH` when set and existing, then a bundled copy under
  /// `$HOME/.local/share/vellum-flutter/pdfium/lib/libpdfium.so`, and finally
  /// falls back to the system search path (`libpdfium.so`).
  static PDFium get _library {
    final cached = _pdfiumCache;
    if (cached != null) return cached;
    final pdfium = PDFium(ffi.DynamicLibrary.open(_resolveLibraryPath()));
    pdfium.FPDF_InitLibrary();
    return _pdfiumCache = pdfium;
  }

  static String _resolveLibraryPath() {
    final envPath = Platform.environment['PDFIUM_PATH'];
    if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
      return envPath;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final bundled =
          '$home/.local/share/vellum-flutter/pdfium/lib/libpdfium.so';
      if (File(bundled).existsSync()) return bundled;
    }
    return 'libpdfium.so';
  }

  static FPDF_DOCUMENT _loadDocument(PDFium pdfium, String path) {
    final pathPtr = path.toNativeUtf8().cast<ffi.Char>();
    try {
      final doc = pdfium.FPDF_LoadDocument(pathPtr, ffi.nullptr);
      if (doc == ffi.nullptr) {
        throw FormatException('not a readable PDF: $path');
      }
      return doc;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Total number of pages in the document.
  int pageCount() {
    _ensureOpen();
    return _library.FPDF_GetPageCount(_doc);
  }

  /// Page label for [index], falling back to `Page ${index + 1}`.
  ///
  /// Throws [RangeError] when [index] is out of bounds.
  String titleAt(int index) {
    _ensureOpen();
    final count = pageCount();
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }
    // FPDF_GetPageLabel reports the required buffer size in bytes, including
    // the two-byte UTF-16 terminator.
    final needed =
        _library.FPDF_GetPageLabel(_doc, index, ffi.nullptr, 0);
    if (needed > 2) {
      final buffer = calloc<ffi.Uint16>(needed ~/ 2);
      try {
        final written = _library.FPDF_GetPageLabel(
          _doc,
          index,
          buffer.cast<ffi.Void>(),
          needed,
        );
        if (written > 2) {
          final units = written ~/ 2;
          // Drop the trailing NUL terminator.
          final label = String.fromCharCodes(buffer.asTypedList(units - 1));
          if (label.isNotEmpty) return label;
        }
      } finally {
        calloc.free(buffer);
      }
    }
    return 'Page ${index + 1}';
  }

  /// Render [index] to PNG bytes at [scale] (1.0 = PDF points).
  ///
  /// Throws [RangeError] when [index] is out of bounds and
  /// [FormatException] when PDFium cannot render the page.
  Future<Uint8List> renderPage(int index, {double scale = defaultScale}) async {
    _ensureOpen();
    final count = pageCount();
    if (index < 0 || index >= count) {
      throw RangeError.range(index, 0, count - 1, 'index');
    }
    final page = _library.FPDF_LoadPage(_doc, index);
    if (page == ffi.nullptr) {
      throw PdfRenderException('failed to render page ${index + 1}');
    }
    FPDF_BITMAP bitmap = ffi.nullptr;
    try {
      final width = (_library.FPDF_GetPageWidthF(page) * scale);
      final height = (_library.FPDF_GetPageHeightF(page) * scale);
      final size = rasterSize(width, height, 1.0);
      bitmap = _library.FPDFBitmap_Create(size.width, size.height, 1);
      if (bitmap == ffi.nullptr) {
        throw PdfRenderException('failed to render page ${index + 1}');
      }
      final rasterWidth = size.width;
      final rasterHeight = size.height;
      _library.FPDFBitmap_FillRect(
          bitmap, 0, 0, rasterWidth, rasterHeight, 0xFFFFFFFF);
      _library.FPDF_RenderPageBitmap(
          bitmap, page, 0, 0, rasterWidth, rasterHeight, 0, 0);
      final buffer = _library.FPDFBitmap_GetBuffer(bitmap);
      final stride = _library.FPDFBitmap_GetStride(bitmap);
      if (buffer == ffi.nullptr || stride <= 0) {
        throw PdfRenderException('failed to render page ${index + 1}');
      }
      // PDFium's default bitmap format is BGRA8888.
      final image = img.Image.fromBytes(
        width: rasterWidth,
        height: rasterHeight,
        bytes: buffer
            .cast<ffi.Uint8>()
            .asTypedList(stride * rasterHeight)
            .buffer,
        rowStride: stride,
        order: img.ChannelOrder.bgra,
      );
      return img.encodePng(image);
    } finally {
      if (bitmap != ffi.nullptr) {
        _library.FPDFBitmap_Destroy(bitmap);
      }
      _library.FPDF_ClosePage(page);
    }
  }
}

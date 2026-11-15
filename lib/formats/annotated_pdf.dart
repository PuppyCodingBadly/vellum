/// Vector-ink PDF export for page-mode handwriting annotations.
///
/// PDFium rasterizes every source page off the UI isolate; the resulting page
/// images are composed into a new PDF at their original point size, and each
/// page-anchored [InkStroke] is drawn over its page as PDF vector paths. Text
/// and reflow anchors are deliberately ignored: their rectangles describe a
/// reflow column, not a page, so they have no page geometry to export.
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import '../core/ink.dart';
import 'pdf_book.dart';

/// Typed failure from annotated PDF export, naming the page when there is one.
///
/// [pageIndex] is zero-based; the message spells it one-based so it matches
/// what the reader shows.
class AnnotatedPdfException implements Exception {
  const AnnotatedPdfException(this.message, {this.pageIndex});

  final String message;

  /// Zero-based page that failed to render, or null for a document-level
  /// failure (unreadable source, invalid arguments).
  final int? pageIndex;

  @override
  String toString() => message;
}

/// One rasterized source page: PNG bytes plus its size in PDF points.
typedef _RasterPage = ({
  int index,
  double widthPoints,
  double heightPoints,
  Uint8List png,
});

/// What the raster isolate sends back. Failures travel as data because
/// custom exception types do not survive the isolate boundary.
typedef _RasterResult = ({
  List<_RasterPage> pages,
  int? failedPage,
  String? error,
});

/// Build a PDF from [sourcePath] with [strokesByPage] drawn on top.
///
/// Every source page is rasterized at [renderScale] and placed on a page of
/// the same point size; strokes keyed by a page index render as vector paths
/// over that page. Pages without strokes are still exported unannotated.
/// Stroke keys outside the document are ignored.
///
/// Throws [AnnotatedPdfException] when the source cannot be read, when a page
/// fails to render (naming that page), or when [renderScale] is invalid.
Future<Uint8List> buildAnnotatedPdf({
  required String sourcePath,
  required Map<int, List<InkStroke>> strokesByPage,
  double renderScale = 2.0,
}) async {
  if (!renderScale.isFinite || renderScale <= 0) {
    throw const AnnotatedPdfException('invalid PDF render scale');
  }
  final raster = await Isolate.run(
    () => _rasterizePages(sourcePath, renderScale),
  );
  final error = raster.error;
  if (error != null) {
    final failedPage = raster.failedPage;
    if (failedPage != null) {
      throw AnnotatedPdfException(
        'failed to render page ${failedPage + 1} of $sourcePath: $error',
        pageIndex: failedPage,
      );
    }
    throw AnnotatedPdfException('could not read PDF $sourcePath: $error');
  }

  final document = PdfDocument();
  for (final source in raster.pages) {
    final format = PdfPageFormat(source.widthPoints, source.heightPoints);
    final page = PdfPage(document, pageFormat: format);
    final graphics = page.getGraphics();
    final rasterImage = img.decodePng(source.png);
    if (rasterImage == null) {
      throw AnnotatedPdfException(
        'failed to decode page ${source.index + 1} of $sourcePath',
        pageIndex: source.index,
      );
    }
    graphics.drawImage(
      PdfImage.fromImage(document, image: rasterImage),
      0,
      0,
      format.width,
      format.height,
    );
    _drawStrokes(
      graphics,
      strokesByPage[source.index] ?? const <InkStroke>[],
      format,
      source.index,
      sourcePath,
    );
  }
  return document.save();
}

/// Render every page with PDFium inside the current (worker) isolate.
///
/// Rendering failures become [_RasterResult] data rather than exceptions so
/// the caller can name the page after the isolate boundary.
Future<_RasterResult> _rasterizePages(String path, double scale) async {
  PdfBook? book;
  try {
    book = PdfBook(path);
    final count = book.pageCount();
    final pages = <_RasterPage>[];
    for (var index = 0; index < count; index++) {
      try {
        final png = await book.renderPage(index, scale: scale);
        final pixels = _pngSize(png);
        pages.add((
          index: index,
          widthPoints: pixels.width / scale,
          heightPoints: pixels.height / scale,
          png: png,
        ));
      } catch (error) {
        return (pages: pages, failedPage: index, error: '$error');
      }
    }
    return (pages: pages, failedPage: null, error: null);
  } catch (error) {
    return (pages: const <_RasterPage>[], failedPage: null, error: '$error');
  } finally {
    book?.close();
  }
}

/// Read the pixel size from a PNG's IHDR chunk.
///
/// PDFium renders at [renderScale] pixels per point, so dividing by the scale
/// recovers the page's point size without a second PDFium call. Only the fixed
/// IHDR header is inspected; decoding the whole image is unnecessary here.
({int width, int height}) _pngSize(Uint8List png) {
  const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (png.length < 24) {
    throw const FormatException('page did not render to a PNG');
  }
  for (var i = 0; i < signature.length; i++) {
    if (png[i] != signature[i]) {
      throw const FormatException('page did not render to a PNG');
    }
  }
  final header = ByteData.sublistView(png);
  return (width: header.getUint32(16), height: header.getUint32(20));
}

/// Draw page-mode strokes over the already-placed page image.
void _drawStrokes(
  PdfGraphics graphics,
  List<InkStroke> strokes,
  PdfPageFormat format,
  int pageIndex,
  String sourcePath,
) {
  for (final stroke in strokes) {
    if (stroke.anchor.kind != InkAnchorKind.page) continue;
    final rect = stroke.anchor.rect;
    if (!rect.left.isFinite ||
        !rect.top.isFinite ||
        !rect.width.isFinite ||
        !rect.height.isFinite) {
      throw AnnotatedPdfException(
        'page ${pageIndex + 1} of $sourcePath has a stroke with an invalid '
        'anchor rectangle',
        pageIndex: pageIndex,
      );
    }
    _drawStroke(graphics, stroke, format);
  }
}

/// Stroke one ink line as PDF vector segments.
///
/// PDF has no per-vertex stroke width, so each segment is stroked separately
/// with the average of its endpoints' pressure-scaled widths. Round caps and
/// joins make the seams between segments invisible.
void _drawStroke(PdfGraphics graphics, InkStroke stroke, PdfPageFormat format) {
  final count = stroke.pointCount;
  if (count == 0) return;
  final rect = stroke.anchor.rect;
  final color = stroke.color;
  final alpha = ((color >> 24) & 0xff) / 255.0;
  final nominalWidth = stroke.width.isFinite && stroke.width > 0
      ? stroke.width
      : 1.0;
  // Stroke width is in the anchor rect's display pixels; page points are
  // larger or smaller by however much the page was scaled to fit the reader.
  final baseWidth = rect.width > 0 && rect.height > 0
      ? nominalWidth *
            ((format.width / rect.width + format.height / rect.height) / 2)
      : nominalWidth;

  graphics
    ..setGraphicState(PdfGraphicState(strokeOpacity: alpha))
    ..setStrokeColor(PdfColor.fromInt(color))
    ..setLineCap(PdfLineCap.round)
    ..setLineJoin(PdfLineJoin.round);

  if (count == 1) {
    final point = _pagePoint(stroke, 0, format);
    graphics
      ..setLineWidth(_pressureWidth(stroke, 0, baseWidth))
      ..moveTo(point.x, point.y)
      ..lineTo(point.x, point.y)
      ..strokePath();
    return;
  }

  for (var i = 0; i < count - 1; i++) {
    final from = _pagePoint(stroke, i, format);
    final to = _pagePoint(stroke, i + 1, format);
    final width =
        (_pressureWidth(stroke, i, baseWidth) +
            _pressureWidth(stroke, i + 1, baseWidth)) /
        2;
    graphics
      ..setLineWidth(width)
      ..moveTo(from.x, from.y)
      ..lineTo(to.x, to.y)
      ..strokePath();
  }
}

/// Map normalized point [index] into PDF page space (origin bottom-left).
///
/// Page anchors cover the whole displayed page, so the normalized coordinates
/// map directly onto the page's point size; the anchor rect's display offset
/// and scale do not belong in page space.
({double x, double y}) _pagePoint(
  InkStroke stroke,
  int index,
  PdfPageFormat format,
) {
  final normalized = stroke.pointAt(index);
  return (
    x: normalized.dx * format.width,
    y: (1 - normalized.dy) * format.height,
  );
}

/// Line width at [index], modulated by pen pressure.
///
/// A zero-pressure stroke still stays visible at a quarter of its nominal
/// width; full pressure reaches the nominal width.
double _pressureWidth(InkStroke stroke, int index, double baseWidth) {
  final raw = stroke.pressureAt(index);
  final pressure = raw.isFinite ? raw.clamp(0.0, 1.0).toDouble() : 0.0;
  return math.max(baseWidth * 0.25, baseWidth * (0.35 + 0.65 * pressure));
}

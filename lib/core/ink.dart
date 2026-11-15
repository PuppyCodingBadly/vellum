/// Anchored handwriting annotations.
///
/// A stroke's points are stored normalized to its anchor rectangle: `x` and
/// `y` are fractions of the rect's width and height, so the same stroke
/// follows its text through reflow, zoom and rotation. Values deliberately
/// may leave `0..1`, because a note drawn in a page margin stays anchored to
/// the text it belongs to.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

/// What an ink stroke is attached to.
enum InkAnchorKind {
  /// A text range (`start`/`end`, inclusive start, exclusive end).
  text,

  /// A whole page; text indices are unused.
  page,

  /// A block of a reflowed document, identified by `start` in the reflow
  /// stream.
  reflowBlock,
}

/// The input mode that produced a stroke.
///
/// Stored with the stroke's owning tool only in the UI; the catalogue keeps
/// strokes themselves, since an eraser removes strokes rather than adding
/// them.
enum InkTool { pen, eraser }

/// Where a stroke lives and the rectangle it is normalized against.
class InkAnchor {
  const InkAnchor({
    required this.kind,
    required this.chapter,
    this.start = 0,
    this.end = 0,
    required this.rect,
  });

  final InkAnchorKind kind;

  /// Zero-based chapter (or page) the anchor belongs to.
  final int chapter;

  /// Start offset, or the reflow block id; unused for [InkAnchorKind.page].
  final int start;

  /// End offset; unused for [InkAnchorKind.page] and
  /// [InkAnchorKind.reflowBlock].
  final int end;

  /// Anchor rectangle in page coordinates: the space stroke points are
  /// normalized to.
  final Rect rect;

  /// JSON form; the rect becomes `[left, top, width, height]`.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'chapter': chapter,
    'start': start,
    'end': end,
    'rect': [rect.left, rect.top, rect.width, rect.height],
  };

  /// Parses [toJson] output, rejecting unknown kinds and non-finite numbers
  /// with a [FormatException].
  factory InkAnchor.fromJson(Map<String, Object?> json) {
    final rawKind = json['kind'];
    InkAnchorKind? kind;
    for (final value in InkAnchorKind.values) {
      if (value.name == rawKind) kind = value;
    }
    if (kind == null) {
      throw FormatException('unknown ink anchor kind: $rawKind');
    }
    final rect = _rectFromJson(json['rect']);
    return InkAnchor(
      kind: kind,
      chapter: _intFromJson(json['chapter'], 'chapter'),
      start: _intFromJson(json['start'], 'start', fallback: 0),
      end: _intFromJson(json['end'], 'end', fallback: 0),
      rect: rect,
    );
  }

  static Rect _rectFromJson(Object? value) {
    if (value is! List || value.length != 4) {
      throw FormatException('ink rect must be [left, top, width, height]');
    }
    final values = [
      for (final element in value) _finiteFromJson(element, 'rect'),
    ];
    if (values[2] < 0 || values[3] < 0) {
      throw FormatException('ink rect width and height must be >= 0');
    }
    return Rect.fromLTWH(values[0], values[1], values[2], values[3]);
  }

  static int _intFromJson(Object? value, String name, {int? fallback}) {
    if (value == null && fallback != null) return fallback;
    if (value is int) return value;
    if (value is num && value.isFinite) return value.toInt();
    throw FormatException('ink anchor $name must be an integer: $value');
  }

  static double _finiteFromJson(Object? value, String name) {
    if (value is num && value.isFinite) return value.toDouble();
    throw FormatException('ink $name must be finite: $value');
  }
}

/// One drawn line inside its anchor rectangle.
class InkStroke {
  InkStroke({
    this.id,
    required this.anchor,
    required this.color,
    required this.width,
    required this.points,
  }) {
    if (points.length % 3 != 0) {
      throw ArgumentError.value(
        points.length,
        'points',
        'must hold x, y, pressure triples',
      );
    }
  }

  /// Database id; null until the library inserted the stroke.
  int? id;

  final InkAnchor anchor;

  /// ARGB color of the line.
  final int color;

  /// Line width in the same units as [anchor]'s rect (page coordinates).
  final double width;

  /// Normalized `x, y, pressure` triples; see the library comment.
  final Float32List points;

  int get pointCount => points.length ~/ 3;

  /// The normalized coordinates of point [index].
  Offset pointAt(int index) {
    _checkPoint(index);
    final base = index * 3;
    return Offset(points[base], points[base + 1]);
  }

  /// Pen pressure of point [index], 0–1.
  double pressureAt(int index) {
    _checkPoint(index);
    return points[index * 3 + 2];
  }

  /// Point [index] mapped into [rect], the rect the caller is currently
  /// laying the anchor out in.
  Offset pointLocal(int index, Rect rect) {
    final normalized = pointAt(index);
    return Offset(
      rect.left + normalized.dx * rect.width,
      rect.top + normalized.dy * rect.height,
    );
  }

  /// Bounding box of the drawn points in [rect]'s coordinates.
  ///
  /// Empty for a stroke without points, positioned at [rect]'s top-left so
  /// callers can still union it.
  Rect boundsIn(Rect rect) {
    if (pointCount == 0) {
      return Rect.fromLTWH(rect.left, rect.top, 0, 0);
    }
    final first = pointLocal(0, rect);
    var left = first.dx;
    var top = first.dy;
    var right = first.dx;
    var bottom = first.dy;
    for (var i = 1; i < pointCount; i++) {
      final point = pointLocal(i, rect);
      left = math.min(left, point.dx);
      top = math.min(top, point.dy);
      right = math.max(right, point.dx);
      bottom = math.max(bottom, point.dy);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// A copy sharing [anchor], [color], [width] and [points]; only the id
  /// differs, which is what an insert needs to fill in.
  InkStroke copyWith({int? id}) => InkStroke(
    id: id ?? this.id,
    anchor: anchor,
    color: color,
    width: width,
    points: points,
  );

  void _checkPoint(int index) {
    if (index < 0 || index >= pointCount) {
      throw RangeError.index(index, this, 'index', null, pointCount);
    }
  }
}

/// Converts strokes to and from the database BLOB.
///
/// The BLOB is little-endian float32 `x, y, pressure` triples, so it is the
/// same layout on every host and needs no JSON round trip.
abstract final class InkCodec {
  /// Encodes [points] with [pressure] as triples.
  ///
  /// A point with a non-finite coordinate is dropped; a missing or
  /// non-finite pressure becomes 1.0, and finite pressures clamp to 0–1.
  /// Deferring the pressure list is allowed, so a client that lacks pressure
  /// (mouse, touch without force) passes the points only.
  static Uint8List encodePoints(List<Offset> points, List<double> pressure) {
    final buffer = ByteData(points.length * 12);
    var offset = 0;
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      if (!point.dx.isFinite || !point.dy.isFinite) continue;
      final rawPressure = i < pressure.length ? pressure[i] : 1.0;
      final value = rawPressure.isFinite
          ? rawPressure.clamp(0.0, 1.0).toDouble()
          : 1.0;
      buffer.setFloat32(offset, point.dx, Endian.little);
      buffer.setFloat32(offset + 4, point.dy, Endian.little);
      buffer.setFloat32(offset + 8, value, Endian.little);
      offset += 12;
    }
    return Uint8List.view(buffer.buffer, 0, offset);
  }

  /// Decodes a BLOB written by [encodePoints].
  ///
  /// A trailing partial triple is ignored so a truncated row can never make
  /// the app throw while opening a book.
  static Float32List decodePoints(Uint8List bytes) {
    final triples = bytes.length ~/ 12;
    final values = Float32List(triples * 3);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < values.length; i++) {
      values[i] = data.getFloat32(i * 4, Endian.little);
    }
    return values;
  }
}

/// Whether [local] touches [stroke] drawn inside [anchorRect].
///
/// [local] is in the same page coordinates as [anchorRect]. The tolerance is
/// [radius] plus half the line width, so a tap picks up the drawn band of a
/// thick stroke as well as the eraser's radius.
bool inkStrokeHit(
  InkStroke stroke,
  Rect anchorRect,
  Offset local, {
  double radius = 6,
}) {
  final count = stroke.pointCount;
  if (count == 0) return false;
  final width = stroke.width.isFinite ? math.max(stroke.width, 0.0) : 0.0;
  final tolerance = radius + width / 2;
  if (count == 1) {
    return (stroke.pointLocal(0, anchorRect) - local).distance <= tolerance;
  }
  var previous = stroke.pointLocal(0, anchorRect);
  for (var i = 1; i < count; i++) {
    final current = stroke.pointLocal(i, anchorRect);
    if (_distanceToSegment(local, previous, current) <= tolerance) return true;
    previous = current;
  }
  return false;
}

/// Shortest distance from [point] to the segment [a]–[b].
double _distanceToSegment(Offset point, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (point - a).distance;
  final ap = point - a;
  final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / lengthSquared)
      .clamp(0.0, 1.0)
      .toDouble();
  return (point - (a + ab * t)).distance;
}

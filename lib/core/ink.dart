/// Anchored handwriting annotations.
///
/// A stroke's points are stored normalized to one of its anchor rectangles:
/// `x` and `y` are fractions of the rect's width and height, so the same
/// stroke follows its text through reflow, zoom and rotation. Values
/// deliberately may leave `0..1`, because a note drawn in a page margin stays
/// anchored to the text it belongs to.
///
/// A text anchor may also carry one rect per laid-out line. Strokes then
/// record which stored line each point was drawn on, and the mapping helpers
/// below interpolate those lines onto the current layout, so a note drawn
/// across a paragraph's lines stays on the lines when they reflow.
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

/// Where a stroke lives and the rectangles it is normalized against.
class InkAnchor {
  const InkAnchor({
    required this.kind,
    required this.chapter,
    this.start = 0,
    this.end = 0,
    required this.rect,
    this.lines = const <Rect>[],
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
  /// normalized to, and the bounds of [lines] when those are present.
  final Rect rect;

  /// One rect per laid-out line of the anchored text, in reading order.
  ///
  /// Empty for anchors that have no per-line geometry (pages, reflow blocks,
  /// and rows written before lines existed); strokes then use [rect].
  final List<Rect> lines;

  /// JSON form; the rect becomes `[left, top, width, height]`, and [lines]
  /// are written only when present so a legacy row stays readable.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'chapter': chapter,
    'start': start,
    'end': end,
    'rect': _rectToJson(rect),
    if (lines.isNotEmpty)
      'lines': [for (final line in lines) _rectToJson(line)],
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
    return InkAnchor(
      kind: kind,
      chapter: _intFromJson(json['chapter'], 'chapter'),
      start: _intFromJson(json['start'], 'start', fallback: 0),
      end: _intFromJson(json['end'], 'end', fallback: 0),
      rect: _rectFromJson(json['rect']),
      lines: _linesFromJson(json['lines']),
    );
  }

  static List<double> _rectToJson(Rect rect) => [
    rect.left,
    rect.top,
    rect.width,
    rect.height,
  ];

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

  static List<Rect> _linesFromJson(Object? value) {
    if (value == null) return const <Rect>[];
    if (value is! List) {
      throw FormatException('ink lines must be a list of rects');
    }
    return [for (final element in value) _rectFromJson(element)];
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

/// One drawn stroke inside its anchor rectangles.
class InkStroke {
  InkStroke({
    this.id,
    required this.anchor,
    required this.color,
    required this.width,
    required this.points,
    this.lineIndices,
  }) {
    if (points.length % 3 != 0) {
      throw ArgumentError.value(
        points.length,
        'points',
        'must hold x, y, pressure triples',
      );
    }
    if (lineIndices != null && lineIndices!.length != pointCount) {
      throw ArgumentError.value(
        lineIndices!.length,
        'lineIndices',
        'must hold one line index per point',
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

  /// Stored line of each point, into [InkAnchor.lines]; null when every point
  /// belongs to line 0 (legacy row, or an anchor without per-line geometry).
  final Uint8List? lineIndices;

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
  Offset pointLocal(int index, Rect rect) =>
      inkPointInLines(this, index, [rect]);

  /// Bounding box of the drawn points in [rect]'s coordinates.
  ///
  /// Empty for a stroke without points, positioned at [rect]'s top-left so
  /// callers can still union it.
  Rect boundsIn(Rect rect) => inkBoundsInLines(this, [rect]);

  /// A copy sharing [anchor], [color], [width], [points] and [lineIndices];
  /// only the id differs, which is what an insert needs to fill in.
  InkStroke copyWith({int? id}) => InkStroke(
    id: id ?? this.id,
    anchor: anchor,
    color: color,
    width: width,
    points: points,
    lineIndices: lineIndices,
  );

  void _checkPoint(int index) {
    if (index < 0 || index >= pointCount) {
      throw RangeError.index(index, this, 'index', null, pointCount);
    }
  }
}

/// Decoded BLOB: normalized `x, y, pressure` triples plus one line index per
/// point (empty for a legacy stride-3 blob).
class InkDecoded {
  const InkDecoded({required this.points, required this.lineIndices});

  final Float32List points;
  final Uint8List lineIndices;
}

/// Converts strokes to and from the database BLOB.
///
/// The current layout is a 5-byte header (`INK1` and stride byte 4) followed
/// by little-endian float32 `x, y, pressure, line` quads. Legacy rows are
/// headerless little-endian float32 `x, y, pressure` triples; [decodePoints]
/// tells them apart by the magic, so a length divisible by both 12 and 16 is
/// unambiguous.
abstract final class InkCodec {
  static const _magic = [0x49, 0x4E, 0x4B, 0x31]; // INK1
  static const _headerSize = 5;
  static const _quadStride = 4;
  static const _tripleStride = 3;

  /// Encodes [points] with [pressure] and [lineIndices].
  ///
  /// A point with a non-finite coordinate is dropped; a missing or
  /// non-finite pressure becomes 1.0, finite pressures clamp to 0–1, and
  /// missing line indices become 0. Passing no [lineIndices] keeps the
  /// legacy triple layout, so callers that have no line data (pages,
  /// reflow blocks) keep writing the compact form.
  static Uint8List encodePoints(
    List<Offset> points,
    List<double> pressure, [
    List<int> lineIndices = const <int>[],
  ]) {
    final withLines = lineIndices.isNotEmpty;
    final bytesPerPoint = (withLines ? _quadStride : _tripleStride) * 4;
    final buffer = ByteData(
      (withLines ? _headerSize : 0) + points.length * bytesPerPoint,
    );
    var offset = 0;
    if (withLines) {
      for (var i = 0; i < _magic.length; i++) {
        buffer.setUint8(i, _magic[i]);
      }
      buffer.setUint8(4, _quadStride);
      offset = _headerSize;
    }
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
      if (withLines) {
        final rawLine = i < lineIndices.length ? lineIndices[i] : 0;
        buffer.setFloat32(
          offset + 12,
          rawLine.clamp(0, 255).toDouble(),
          Endian.little,
        );
      }
      offset += bytesPerPoint;
    }
    return Uint8List.view(buffer.buffer, 0, offset);
  }

  /// Decodes a BLOB written by [encodePoints] or by an older build.
  ///
  /// A trailing partial record is ignored so a truncated row can never make
  /// the app throw while opening a book. A header with an unknown stride is
  /// rejected, because guessing would misplace the points.
  static InkDecoded decodePoints(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (_hasMagic(bytes)) {
      final stride = bytes[4];
      if (stride != _quadStride) {
        throw FormatException('unsupported ink blob stride: $stride');
      }
      final count = (bytes.length - _headerSize) ~/ 16;
      final points = Float32List(count * 3);
      final lineIndices = Uint8List(count);
      for (var i = 0; i < count; i++) {
        final base = _headerSize + i * 16;
        points[i * 3] = data.getFloat32(base, Endian.little);
        points[i * 3 + 1] = data.getFloat32(base + 4, Endian.little);
        points[i * 3 + 2] = data.getFloat32(base + 8, Endian.little);
        final rawLine = data.getFloat32(base + 12, Endian.little);
        lineIndices[i] = rawLine.isFinite
            ? math.min(255, math.max(0, rawLine.round()))
            : 0;
      }
      return InkDecoded(points: points, lineIndices: lineIndices);
    }
    final triples = bytes.length ~/ 12;
    final values = Float32List(triples * 3);
    for (var i = 0; i < values.length; i++) {
      values[i] = data.getFloat32(i * 4, Endian.little);
    }
    return InkDecoded(points: values, lineIndices: Uint8List(0));
  }

  static bool _hasMagic(Uint8List bytes) {
    if (bytes.length < _headerSize) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }
}

/// Point [index] of [stroke] mapped into the current layout's [currentLines].
///
/// With no current lines the stroke's own [InkAnchor.rect] is the layout.
/// With at most one stored line every point maps into the first current
/// line. Otherwise each point's stored line is interpolated proportionally
/// onto the current line count, so an equal count maps one-to-one and a
/// reflowed paragraph stretches or squeezes the drawing with its lines.
Offset inkPointInLines(InkStroke stroke, int index, List<Rect> currentLines) {
  final normalized = stroke.pointAt(index);
  if (currentLines.isEmpty) {
    return _denormalize(normalized, stroke.anchor.rect);
  }
  final storedLines = stroke.anchor.lines;
  if (storedLines.length <= 1) {
    return _denormalize(normalized, currentLines.first);
  }
  final line = stroke.lineIndices == null ? 0 : stroke.lineIndices![index];
  final fraction = line * (currentLines.length - 1) / (storedLines.length - 1);
  final lastLine = currentLines.length - 1;
  final lower = math.min(lastLine, math.max(0, fraction.floor()));
  final upper = math.min(lastLine, math.max(0, fraction.ceil()));
  final rect = lower == upper
      ? currentLines[lower]
      : Rect.lerp(currentLines[lower], currentLines[upper], fraction - lower)!;
  return _denormalize(normalized, rect);
}

/// Bounding box of [stroke] in the current layout's [currentLines].
Rect inkBoundsInLines(InkStroke stroke, List<Rect> currentLines) {
  final origin = currentLines.isEmpty ? stroke.anchor.rect : currentLines.first;
  if (stroke.pointCount == 0) {
    return Rect.fromLTWH(origin.left, origin.top, 0, 0);
  }
  final first = inkPointInLines(stroke, 0, currentLines);
  var left = first.dx;
  var top = first.dy;
  var right = first.dx;
  var bottom = first.dy;
  for (var i = 1; i < stroke.pointCount; i++) {
    final point = inkPointInLines(stroke, i, currentLines);
    left = math.min(left, point.dx);
    top = math.min(top, point.dy);
    right = math.max(right, point.dx);
    bottom = math.max(bottom, point.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// [stroke]'s width scaled from its stored line height to the current one.
///
/// A stroke drawn on 20px lines and reflowed onto 30px lines gets 1.5x as
/// thick. The factor clamps to 0.5–3.0 so extreme reflow cannot erase or
/// swamp the drawing.
double inkWidthInLines(InkStroke stroke, List<Rect> currentLines) {
  final width = stroke.width.isFinite ? math.max(stroke.width, 0.0) : 0.0;
  // Without a current layout there is no reflow to scale against.
  if (currentLines.isEmpty) return width;
  final storedLines = stroke.anchor.lines;
  final storedHeight = storedLines.isEmpty
      ? stroke.anchor.rect.height
      : storedLines.first.height;
  final currentHeight = currentLines.first.height;
  if (!storedHeight.isFinite || storedHeight <= 0 || !currentHeight.isFinite) {
    return width;
  }
  return width * (currentHeight / storedHeight).clamp(0.5, 3.0);
}

/// Whether [local] touches [stroke] drawn across [currentLines].
///
/// Points are mapped through [inkPointInLines]; the tolerance is [radius]
/// plus half [inkWidthInLines], so a tap picks up the drawn band of a thick
/// stroke as well as the eraser's radius.
bool inkStrokeHitLines(
  InkStroke stroke,
  List<Rect> currentLines,
  Offset local, {
  double radius = 6,
}) {
  final count = stroke.pointCount;
  if (count == 0) return false;
  final tolerance = radius + inkWidthInLines(stroke, currentLines) / 2;
  if (count == 1) {
    return (inkPointInLines(stroke, 0, currentLines) - local).distance <=
        tolerance;
  }
  var previous = inkPointInLines(stroke, 0, currentLines);
  for (var i = 1; i < count; i++) {
    final current = inkPointInLines(stroke, i, currentLines);
    if (_distanceToSegment(local, previous, current) <= tolerance) return true;
    previous = current;
  }
  return false;
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
}) => inkStrokeHitLines(stroke, [anchorRect], local, radius: radius);

Offset _denormalize(Offset normalized, Rect rect) => Offset(
  rect.left + normalized.dx * rect.width,
  rect.top + normalized.dy * rect.height,
);

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

/// A transparent surface for anchored handwriting.
///
/// [InkSurface] lays a paint layer over its child and turns stylus (and, for
/// desktop, mouse) drags into [InkStroke]s. A stroke is captured in surface
/// coordinates, then normalized into the rectangle of the anchor that
/// [InkSurface.anchorBuilder] derives from the stroke's first and last point.
/// Touch stays out of the gesture arena, so scrolling, selection and links
/// under the surface keep working untouched.
library;

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/ink.dart';

/// Draws [strokes] and the in-flight preview over a page.
///
/// A stroke's points are stored normalized to its anchor rectangle, so the
/// painter asks [rectFor] where that rectangle sits on the surface. The same
/// [rectFor] answers the eraser's hit test.
class InkSurfacePainter extends CustomPainter {
  InkSurfacePainter({
    required this.strokes,
    required this.rectFor,
    required this.tool,
    this.previewPoints = const <Offset>[],
    this.previewPressures = const <double>[],
    this.previewColor = const Color(0xFF000000),
    this.previewWidth = 1,
    this.previewRevision = 0,
  });

  /// Committed strokes, in paint order.
  final List<InkStroke> strokes;

  /// Where a stroke's anchor currently sits, in surface coordinates.
  final Rect Function(InkStroke stroke) rectFor;

  /// Only [InkTool.pen] previews; the eraser paints nothing of its own.
  final InkTool tool;

  /// Raw surface-space points of the stroke in progress.
  final List<Offset> previewPoints;

  /// Pressure parallel to [previewPoints].
  final List<double> previewPressures;

  final Color previewColor;
  final double previewWidth;

  /// Bumped by [InkSurface] for every preview change. Points are appended in
  /// place, so their list identity alone would miss the update.
  final int previewRevision;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _paintStroke(canvas, stroke);
    }
    if (previewPoints.isNotEmpty) {
      _paintPoints(
        canvas,
        points: previewPoints,
        pressures: previewPressures,
        color: previewColor,
        width: previewWidth,
      );
    }
  }

  void _paintStroke(Canvas canvas, InkStroke stroke) {
    final rect = rectFor(stroke);
    final count = stroke.pointCount;
    final points = <Offset>[
      for (var i = 0; i < count; i++) stroke.pointLocal(i, rect),
    ];
    final pressures = <double>[
      for (var i = 0; i < count; i++) _pressureAt(stroke, i),
    ];
    _paintPoints(
      canvas,
      points: points,
      pressures: pressures,
      color: Color(stroke.color),
      width: stroke.width,
    );
  }

  /// Pressure triples carry 0 for devices that cannot report it; those strokes
  /// read at full width.
  static double _pressureAt(InkStroke stroke, int index) {
    final pressure = stroke.pressureAt(index);
    return pressure.isFinite && pressure > 0 ? pressure : 1;
  }

  /// Draws [points] as quadratic segments through their midpoints, each
  /// segment keeping the width of the pressure that produced it.
  static void _paintPoints(
    Canvas canvas, {
    required List<Offset> points,
    required List<double> pressures,
    required Color color,
    required double width,
  }) {
    if (points.isEmpty || !width.isFinite || width <= 0) return;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        _widthAt(width, _pressureOrOne(pressures, 0)) / 2,
        paint,
      );
      return;
    }

    paint.style = PaintingStyle.stroke;
    var start = points.first;
    for (var i = 1; i < points.length; i++) {
      final control = points[i];
      final end = i == points.length - 1
          ? control
          : Offset.lerp(control, points[i + 1], 0.5)!;
      paint.strokeWidth = _widthAt(width, _pressureOrOne(pressures, i));
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(control.dx, control.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);
      start = end;
    }
  }

  static double _pressureOrOne(List<double> pressures, int index) {
    if (index >= pressures.length) return 1;
    final pressure = pressures[index];
    return pressure.isFinite && pressure > 0 ? pressure : 1;
  }

  static double _widthAt(double base, double pressure) {
    final clamped = pressure.isFinite && pressure > 0 ? pressure : 1.0;
    return (base * (0.5 + 0.5 * clamped)).clamp(0.5, double.infinity);
  }

  @override
  bool shouldRepaint(covariant InkSurfacePainter oldDelegate) {
    // rectFor is deliberately not compared: a geometry change arrives with new
    // strokes and anchors, and a new function identity on an unrelated rebuild
    // must not force a repaint.
    return oldDelegate.strokes != strokes ||
        oldDelegate.tool != tool ||
        oldDelegate.previewRevision != previewRevision ||
        oldDelegate.previewColor != previewColor ||
        oldDelegate.previewWidth != previewWidth;
  }
}

/// A page-sized canvas for anchored handwriting.
///
/// Wrap the widget the strokes belong to; the child keeps its own layout and
/// hit testing while the ink layer sits above it. The parent supplies [strokes]
/// (a new list whenever ink changes), [rectFor] to locate each stroke's anchor
/// on the surface, and [anchorBuilder] to decide which anchor a new stroke
/// belongs to.
class InkSurface extends StatefulWidget {
  const InkSurface({
    super.key,
    required this.enabled,
    required this.tool,
    required this.color,
    required this.width,
    required this.strokes,
    required this.rectFor,
    required this.anchorBuilder,
    required this.onStrokeComplete,
    required this.onErase,
    required this.child,
  });

  /// When false the surface rejects every pointer, including stylus.
  final bool enabled;

  final InkTool tool;

  /// Ink colour for a new stroke.
  final Color color;

  /// Stroke width in surface (and anchor-rect) logical pixels.
  final double width;

  final List<InkStroke> strokes;

  /// The surface-space rectangle of [stroke]'s anchor.
  final Rect Function(InkStroke stroke) rectFor;

  /// Builds the anchor for a finished stroke from its first and last
  /// surface-space points. Its `rect` defines the normalization rectangle;
  /// points may land outside 0..1 when the pen leaves that rectangle.
  final InkAnchor Function(Offset firstLocal, Offset lastLocal) anchorBuilder;

  final ValueChanged<InkStroke> onStrokeComplete;
  final ValueChanged<InkStroke> onErase;
  final Widget child;

  @override
  State<InkSurface> createState() => _InkSurfaceState();
}

class _InkSurfaceState extends State<InkSurface> {
  static const double _eraserRadius = 12;
  static const double _minPointDistance = 0.5;

  /// Points of the stroke in progress, in surface coordinates.
  final List<Offset> _points = <Offset>[];
  final List<double> _pressures = <double>[];

  /// Strokes already erased in this sequence, so a drag reports each once.
  final Set<InkStroke> _erased = Set<InkStroke>.identity();

  bool _drawing = false;
  bool _erasing = false;
  int _previewRevision = 0;

  void _onStart(Offset local, double pressure) {
    _erased.clear();
    if (widget.tool == InkTool.eraser) {
      _erasing = true;
      _eraseAt(local);
      return;
    }
    _drawing = true;
    setState(() {
      _points
        ..clear()
        ..add(local);
      _pressures
        ..clear()
        ..add(_pressureOrOne(pressure));
      _previewRevision++;
    });
  }

  void _onUpdate(Offset local, double pressure) {
    if (_erasing) {
      _eraseAt(local);
      return;
    }
    if (!_drawing) return;
    if ((local - _points.last).distanceSquared <
        _minPointDistance * _minPointDistance) {
      return;
    }
    setState(() {
      _points.add(local);
      _pressures.add(_pressureOrOne(pressure));
      _previewRevision++;
    });
  }

  void _onEnd() {
    if (_erasing) {
      _erasing = false;
      return;
    }
    if (!_drawing) return;
    _drawing = false;
    final stroke = _buildStroke();
    setState(() {
      _points.clear();
      _pressures.clear();
      _previewRevision++;
    });
    if (stroke != null) widget.onStrokeComplete(stroke);
  }

  void _onCancel() {
    _drawing = false;
    _erasing = false;
    if (_points.isEmpty) return;
    setState(() {
      _points.clear();
      _pressures.clear();
      _previewRevision++;
    });
  }

  /// Normalizes the captured surface points into the new anchor's rectangle.
  /// Values outside 0..1 are kept: a stroke may legitimately leave its anchor.
  InkStroke? _buildStroke() {
    if (_points.isEmpty) return null;
    final anchor = widget.anchorBuilder(_points.first, _points.last);
    final rect = anchor.rect;
    final scaleX = rect.width == 0 ? 1.0 : 1 / rect.width;
    final scaleY = rect.height == 0 ? 1.0 : 1 / rect.height;
    final normalized = <Offset>[
      for (final point in _points)
        Offset(
          (point.dx - rect.left) * scaleX,
          (point.dy - rect.top) * scaleY,
        ),
    ];
    return InkStroke(
      anchor: anchor,
      color: widget.color.toARGB32(),
      width: widget.width,
      // The codec BLOB already is the float32 triple layout the stroke stores.
      points: Float32List.sublistView(
        InkCodec.encodePoints(normalized, _pressures),
      ),
    );
  }

  void _eraseAt(Offset local) {
    for (final stroke in widget.strokes) {
      if (_erased.contains(stroke)) continue;
      if (inkStrokeHit(
        stroke,
        widget.rectFor(stroke),
        local,
        radius: _eraserRadius,
      )) {
        _erased.add(stroke);
        widget.onErase(stroke);
      }
    }
  }

  /// Mouse and trackpad-style devices report no pressure; a stroke from one
  /// reads at full width.
  static double _pressureOrOne(double pressure) =>
      pressure.isFinite && pressure > 0 ? pressure : 1.0;

  @override
  void didUpdateWidget(covariant InkSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Disabling rebuilds the detector without a recognizer, so the sequence
    // cannot end itself; drop its half-drawn preview here.
    if (!widget.enabled && oldWidget.enabled) {
      _drawing = false;
      _erasing = false;
      _points.clear();
      _pressures.clear();
      _previewRevision++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final gestures = widget.enabled
        ? <Type, GestureRecognizerFactory>{
            _InkGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<_InkGestureRecognizer>(
                  () => _InkGestureRecognizer(debugOwner: this),
                  (recognizer) {
                    recognizer
                      ..onStart = _onStart
                      ..onUpdate = _onUpdate
                      ..onEnd = _onEnd
                      ..onCancel = _onCancel;
                  },
                ),
          }
        : const <Type, GestureRecognizerFactory>{};

    return RawGestureDetector(
      gestures: gestures,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: InkSurfacePainter(
                  strokes: widget.strokes,
                  rectFor: widget.rectFor,
                  tool: widget.tool,
                  previewPoints: _points,
                  previewPressures: _pressures,
                  previewColor: widget.color,
                  previewWidth: widget.width,
                  previewRevision: _previewRevision,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A one-pointer recognizer for ink: stylus and mouse only.
///
/// Touch is not tracked at all, which is what lets a scrollable or selectable
/// child own touch gestures underneath the surface.
class _InkGestureRecognizer extends OneSequenceGestureRecognizer {
  _InkGestureRecognizer({super.debugOwner});

  void Function(Offset local, double pressure)? onStart;
  void Function(Offset local, double pressure)? onUpdate;
  void Function()? onEnd;
  void Function()? onCancel;

  static const Set<PointerDeviceKind> _kinds = <PointerDeviceKind>{
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
  };

  @override
  String get debugDescription => 'ink drawing';

  int? _pointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (_pointer != null) return false;
    if (!_kinds.contains(event.kind)) return false;
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryMouseButton) == 0) {
      return false;
    }
    return true;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    // Claim the pointer before the first move: a scrollable under the surface
    // would otherwise eat the first few pixels and swallow short strokes.
    resolve(GestureDisposition.accepted);
    onStart?.call(event.localPosition, event.pressure);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onUpdate?.call(event.localPosition, event.pressure);
    } else if (event is PointerUpEvent) {
      _finish(end: true);
    } else if (event is PointerCancelEvent) {
      _finish(end: false);
    }
  }

  void _finish({required bool end}) {
    final pointer = _pointer;
    if (pointer == null) return;
    _pointer = null;
    // Lifting the pointer stops tracking; didStopTrackingLastPointer then sees
    // no active pointer and stays quiet.
    stopTrackingPointer(pointer);
    (end ? onEnd : onCancel)?.call();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    onCancel?.call();
  }

  @override
  void rejectGesture(int pointer) {
    final wasActive = _pointer == pointer;
    _pointer = null;
    stopTrackingPointer(pointer);
    if (wasActive) onCancel?.call();
  }
}

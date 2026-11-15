/// Widget tests for the anchored handwriting surface: pointer admission,
/// normalization, the eraser, and painter invalidation.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/ink.dart';
import 'package:vellum/ui/ink/ink_surface.dart';

/// The page the fake `anchorBuilder` reports, in surface coordinates.
const Rect page = Rect.fromLTWH(20, 30, 160, 180);

/// A stroke normalized into [lines], one stored line index per point.
///
/// [rect] is the anchor's union rect; [lines] defaults to just [rect].
InkStroke strokeThrough(
  List<Offset> normalized, {
  Rect rect = page,
  List<Rect>? lines,
  List<int>? lineIndices,
}) {
  final boxes = lines ?? <Rect>[rect];
  final decoded = InkCodec.decodePoints(
    InkCodec.encodePoints(
      normalized,
      List<double>.filled(normalized.length, 1),
      lineIndices ?? List<int>.filled(normalized.length, 0),
    ),
  );
  return InkStroke(
    anchor: InkAnchor(
      kind: InkAnchorKind.text,
      chapter: 1,
      rect: rect,
      lines: boxes,
    ),
    color: const Color(0xFF000000).toARGB32(),
    width: 3,
    points: decoded.points,
    lineIndices: decoded.lineIndices,
  );
}

void main() {
  Widget harness({
    bool enabled = true,
    InkTool tool = InkTool.pen,
    List<InkStroke> strokes = const <InkStroke>[],
    List<Rect> Function(InkStroke)? linesFor,
    InkAnchor Function(Offset, Offset)? anchorBuilder,
    ValueChanged<InkStroke>? onStrokeComplete,
    ValueChanged<InkStroke>? onErase,
  }) {
    List<Rect> boxesOf(InkStroke stroke) => stroke.anchor.lines.isEmpty
        ? <Rect>[stroke.anchor.rect]
        : stroke.anchor.lines;
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: InkSurface(
              enabled: enabled,
              tool: tool,
              color: const Color(0xFF112233),
              width: 3,
              strokes: strokes,
              linesFor: linesFor ?? boxesOf,
              anchorBuilder:
                  anchorBuilder ??
                  (first, last) => const InkAnchor(
                    kind: InkAnchorKind.text,
                    chapter: 2,
                    rect: page,
                  ),
              onStrokeComplete: onStrokeComplete ?? (_) {},
              onErase: onErase ?? (_) {},
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  Offset surfaceTopLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byType(InkSurface));

  testWidgets('a stylus drag emits one stroke normalized to the anchor', (
    tester,
  ) async {
    final completed = <InkStroke>[];
    await tester.pumpWidget(harness(onStrokeComplete: completed.add));
    final origin = surfaceTopLeft(tester);

    final gesture = await tester.startGesture(
      origin + const Offset(40, 50),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(origin + const Offset(80, 110));
    await gesture.moveTo(origin + const Offset(120, 140));
    await gesture.up();
    await tester.pump();

    expect(completed, hasLength(1));
    final stroke = completed.single;
    expect(stroke.anchor.chapter, 2);
    expect(stroke.anchor.rect, page);
    expect(stroke.color, const Color(0xFF112233).toARGB32());
    expect(stroke.width, 3);
    expect(stroke.pointCount, 3);
    // Pressure is absent from the synthetic stylus, so it reads at full width.
    for (var i = 0; i < stroke.pointCount; i++) {
      expect(stroke.points[i * 3 + 2], 1.0);
    }
    final expected = [
      const Offset(40, 50),
      const Offset(80, 110),
      const Offset(120, 140),
    ];
    for (var i = 0; i < expected.length; i++) {
      final local = stroke.pointLocal(i, page);
      expect(local.dx, closeTo(expected[i].dx, 0.01));
      expect(local.dy, closeTo(expected[i].dy, 0.01));
    }
    // Stored points are normalized, not raw.
    expect(stroke.points[0], closeTo((40 - page.left) / page.width, 0.001));
  });

  testWidgets('a touch drag stays with the surface and emits nothing', (
    tester,
  ) async {
    final completed = <InkStroke>[];
    await tester.pumpWidget(harness(onStrokeComplete: completed.add));
    final origin = surfaceTopLeft(tester);

    final gesture = await tester.startGesture(
      origin + const Offset(40, 50),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(origin + const Offset(120, 140));
    await gesture.up();
    await tester.pump();

    expect(completed, isEmpty);
  });

  testWidgets('a mouse drag also draws, for desktop use', (tester) async {
    final completed = <InkStroke>[];
    await tester.pumpWidget(harness(onStrokeComplete: completed.add));
    final origin = surfaceTopLeft(tester);

    final gesture = await tester.startGesture(
      origin + const Offset(40, 50),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(origin + const Offset(120, 140));
    await gesture.up();
    await tester.pump();

    expect(completed, hasLength(1));
  });

  testWidgets('a disabled surface ignores a stylus drag', (tester) async {
    final completed = <InkStroke>[];
    await tester.pumpWidget(
      harness(enabled: false, onStrokeComplete: completed.add),
    );
    final origin = surfaceTopLeft(tester);

    final gesture = await tester.startGesture(
      origin + const Offset(40, 50),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(origin + const Offset(120, 140));
    await gesture.up();
    await tester.pump();

    expect(completed, isEmpty);
  });

  testWidgets('the eraser removes only the stroke it touches', (tester) async {
    final upper = strokeThrough(const [Offset(0.1, 0.2), Offset(0.9, 0.2)]);
    final lower = strokeThrough(const [Offset(0.1, 0.8), Offset(0.9, 0.8)]);
    final erased = <InkStroke>[];
    final completed = <InkStroke>[];
    await tester.pumpWidget(
      harness(
        tool: InkTool.eraser,
        strokes: [upper, lower],
        onErase: erased.add,
        onStrokeComplete: completed.add,
      ),
    );
    final origin = surfaceTopLeft(tester);
    final y = page.top + 0.2 * page.height;

    final gesture = await tester.startGesture(
      origin + Offset(page.left + 0.1 * page.width, y),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(origin + Offset(page.left + 0.9 * page.width, y));
    await gesture.up();
    await tester.pump();

    expect(erased, hasLength(1));
    expect(erased.single, same(upper));
    expect(completed, isEmpty);
  });

  testWidgets('a stroke across two lines stores each line and follows it', (
    tester,
  ) async {
    const first = Rect.fromLTWH(20, 30, 160, 20);
    const second = Rect.fromLTWH(20, 50, 160, 20);
    const union = Rect.fromLTWH(20, 30, 160, 40);
    final completed = <InkStroke>[];
    await tester.pumpWidget(
      harness(
        onStrokeComplete: completed.add,
        linesFor: (_) => const <Rect>[first, second],
        anchorBuilder: (firstLocal, lastLocal) => const InkAnchor(
          kind: InkAnchorKind.text,
          chapter: 2,
          start: 1,
          end: 39,
          rect: union,
          lines: <Rect>[first, second],
        ),
      ),
    );
    final origin = surfaceTopLeft(tester);

    final gesture = await tester.startGesture(
      origin + const Offset(30, 38),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.moveTo(origin + const Offset(60, 38));
    await gesture.moveTo(origin + const Offset(90, 58));
    await gesture.moveTo(origin + const Offset(120, 58));
    await gesture.up();
    await tester.pump();

    final stroke = completed.single;
    expect(stroke.anchor.rect, union);
    expect(stroke.anchor.lines, <Rect>[first, second]);
    expect(stroke.lineIndices, isNotNull);
    // Two points landed in each line box.
    expect(stroke.lineIndices!.toList(), <int>[0, 0, 1, 1]);
    const drawn = <Offset>[
      Offset(30, 38),
      Offset(60, 38),
      Offset(90, 58),
      Offset(120, 58),
    ];
    for (var i = 0; i < drawn.length; i++) {
      final mapped = inkPointInLines(stroke, i, const <Rect>[first, second]);
      expect(mapped.dx, closeTo(drawn[i].dx, 0.01));
      expect(mapped.dy, closeTo(drawn[i].dy, 0.01));
    }

    // A font-size change moves and grows both lines; each point stays on the
    // line it was drawn on instead of drifting with the union rect.
    const taller = <Rect>[
      Rect.fromLTWH(20, 30, 200, 30),
      Rect.fromLTWH(20, 60, 200, 30),
    ];
    final onFirst = inkPointInLines(stroke, 0, taller);
    final onSecond = inkPointInLines(stroke, 2, taller);
    expect(taller[0].contains(onFirst), isTrue);
    expect(taller[1].contains(onSecond), isTrue);
    expect(onSecond.dy, greaterThan(taller[1].top));
    // Width scales with the line height, and the bounds grow with the lines.
    expect(inkWidthInLines(stroke, taller), greaterThan(stroke.width));
    expect(
      inkBoundsInLines(stroke, taller).height,
      greaterThan(inkBoundsInLines(stroke, const <Rect>[first, second]).height),
    );
  });

  testWidgets('the eraser follows the per-line mapping', (tester) async {
    const original = <Rect>[
      Rect.fromLTWH(20, 30, 160, 20),
      Rect.fromLTWH(20, 50, 160, 20),
    ];
    const union = Rect.fromLTWH(20, 30, 160, 40);
    const shifted = <Rect>[
      Rect.fromLTWH(20, 60, 160, 20),
      Rect.fromLTWH(20, 100, 160, 20),
    ];
    final stroke = strokeThrough(
      const <Offset>[Offset(0.5, 0.5), Offset(0.5, 0.5)],
      rect: union,
      lines: original,
      lineIndices: <int>[0, 1],
    );
    final erased = <InkStroke>[];
    await tester.pumpWidget(
      harness(
        tool: InkTool.eraser,
        strokes: <InkStroke>[stroke],
        linesFor: (_) => shifted,
        onErase: erased.add,
      ),
    );
    final origin = surfaceTopLeft(tester);

    // The old, stored position no longer has any ink.
    var gesture = await tester.startGesture(
      origin + const Offset(100, 40),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.up();
    await tester.pump();
    expect(erased, isEmpty);

    // The point mapped onto the first shifted line is erased.
    gesture = await tester.startGesture(
      origin + const Offset(100, 70),
      kind: PointerDeviceKind.stylus,
    );
    await gesture.up();
    await tester.pump();
    expect(erased, <InkStroke>[stroke]);
  });

  test('the painter repaints on strokes and tool changes only', () {
    InkSurfacePainter painter(
      List<InkStroke> strokes, {
      InkTool tool = InkTool.pen,
    }) => InkSurfacePainter(
      strokes: strokes,
      linesFor: (stroke) => stroke.anchor.lines.isEmpty
          ? <Rect>[stroke.anchor.rect]
          : stroke.anchor.lines,
      tool: tool,
    );

    final empty = <InkStroke>[];
    final painted = [
      strokeThrough(const [Offset(0.1, 0.2), Offset(0.9, 0.2)]),
    ];

    expect(painter(empty).shouldRepaint(painter(empty)), isFalse);
    expect(painter(empty).shouldRepaint(painter(painted)), isTrue);
    expect(painter(painted).shouldRepaint(painter(painted)), isFalse);
    expect(
      painter(empty, tool: InkTool.eraser).shouldRepaint(painter(empty)),
      isTrue,
    );
  });
}

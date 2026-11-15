/// Widget tests for the anchored handwriting surface: pointer admission,
/// normalization, the eraser, and painter invalidation.
library;

import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vellum/core/ink.dart';
import 'package:vellum/ui/ink/ink_surface.dart';

/// The page the fake `anchorBuilder` reports, in surface coordinates.
const Rect page = Rect.fromLTWH(20, 30, 160, 180);

InkStroke strokeThrough(List<Offset> normalized) => InkStroke(
  anchor: const InkAnchor(kind: InkAnchorKind.text, chapter: 1, rect: page),
  color: const Color(0xFF000000).toARGB32(),
  width: 3,
  points: Float32List.sublistView(
    InkCodec.encodePoints(
      normalized,
      List<double>.filled(normalized.length, 1),
    ),
  ),
);

void main() {
  Widget harness({
    bool enabled = true,
    InkTool tool = InkTool.pen,
    List<InkStroke> strokes = const <InkStroke>[],
    ValueChanged<InkStroke>? onStrokeComplete,
    ValueChanged<InkStroke>? onErase,
  }) {
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
              rectFor: (stroke) => stroke.anchor.rect,
              anchorBuilder: (first, last) => const InkAnchor(
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

  test('the painter repaints on strokes and tool changes only', () {
    InkSurfacePainter painter(
      List<InkStroke> strokes, {
      InkTool tool = InkTool.pen,
    }) => InkSurfacePainter(
      strokes: strokes,
      rectFor: (stroke) => stroke.anchor.rect,
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

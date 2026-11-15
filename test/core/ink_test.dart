import 'dart:typed_data';
import 'dart:ui';

import 'package:test/test.dart';
import 'package:vellum/core/ink.dart';

void main() {
  const anchorRect = Rect.fromLTWH(10, 20, 100, 200);

  InkStroke buildStroke(
    List<Offset> points, {
    List<double> pressure = const <double>[],
    List<int>? lineIndices,
    double width = 2,
    InkAnchorKind kind = InkAnchorKind.text,
    int chapter = 3,
    int start = 4,
    int end = 9,
    Rect rect = anchorRect,
    List<Rect> lines = const <Rect>[],
  }) {
    final decoded = InkCodec.decodePoints(
      InkCodec.encodePoints(points, pressure, lineIndices ?? const <int>[]),
    );
    return InkStroke(
      anchor: InkAnchor(
        kind: kind,
        chapter: chapter,
        start: start,
        end: end,
        rect: rect,
        lines: lines,
      ),
      color: 0xFF102030,
      width: width,
      points: decoded.points,
      lineIndices: decoded.lineIndices.isEmpty ? null : decoded.lineIndices,
    );
  }

  group('InkCodec', () {
    test('round-trips points and pressure through little-endian float32', () {
      final points = const [Offset(0, 0), Offset(0.5, 0.25), Offset(-0.1, 1.2)];
      final pressure = const [0.125, 0.5, 0.875];

      final encoded = InkCodec.encodePoints(points, pressure);
      expect(encoded, hasLength(points.length * 12));

      final decoded = InkCodec.decodePoints(encoded);
      expect(decoded.points, hasLength(9));
      expect(decoded.lineIndices, isEmpty);
      for (var i = 0; i < points.length; i++) {
        expect(decoded.points[i * 3], closeTo(points[i].dx, 1e-6));
        expect(decoded.points[i * 3 + 1], closeTo(points[i].dy, 1e-6));
        expect(decoded.points[i * 3 + 2], closeTo(pressure[i], 1e-6));
      }
    });

    test('round-trips line indices through the INK1 quad layout', () {
      final points = const [Offset(0, 0), Offset(0.5, 0.5), Offset(1, 1)];
      final pressure = const [0.25, 0.5, 0.75];
      const indices = [0, 1, 2];

      final encoded = InkCodec.encodePoints(points, pressure, indices);
      expect(encoded.sublist(0, 4), [0x49, 0x4E, 0x4B, 0x31]); // INK1
      expect(encoded[4], 4);
      // Three quads: 48 data bytes is also a whole number of legacy triples,
      // so only the magic tells the layouts apart.
      expect(encoded, hasLength(5 + points.length * 16));

      final decoded = InkCodec.decodePoints(encoded);
      expect(decoded.points, hasLength(9));
      expect(decoded.lineIndices, isNotEmpty);
      expect(decoded.lineIndices, indices);
      for (var i = 0; i < points.length; i++) {
        expect(decoded.points[i * 3], closeTo(points[i].dx, 1e-6));
        expect(decoded.points[i * 3 + 1], closeTo(points[i].dy, 1e-6));
        expect(decoded.points[i * 3 + 2], closeTo(pressure[i], 1e-6));
      }
    });

    test('decodes a headerless 48-byte blob as four legacy triples', () {
      final legacy = InkCodec.encodePoints(const [
        Offset(0.1, 0.2),
        Offset(0.3, 0.4),
        Offset(0.5, 0.6),
        Offset(0.7, 0.8),
      ], const []);
      expect(legacy, hasLength(48));
      expect(legacy.length % 16, 0);

      final decoded = InkCodec.decodePoints(legacy);
      expect(decoded.points, hasLength(12));
      expect(decoded.lineIndices, isEmpty);
      expect(decoded.points[9], closeTo(0.7, 1e-6));
    });

    test('encode/decode leave an empty stroke empty', () {
      final encoded = InkCodec.encodePoints(const [], const []);
      expect(encoded, isEmpty);
      expect(InkCodec.decodePoints(encoded).points, isEmpty);
      expect(InkCodec.decodePoints(encoded).lineIndices, isEmpty);
    });

    test('missing pressure becomes 1.0 and extra pressure is ignored', () {
      final decoded = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.2), Offset(0.3, 0.4)],
          const [0.25],
        ),
      ).points;
      expect(decoded[2], closeTo(0.25, 1e-6));
      expect(decoded[5], closeTo(1.0, 1e-6));

      final ignored = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.2)],
          const [0.25, 0.75, 0.5],
        ),
      ).points;
      expect(ignored, hasLength(3));
    });

    test('drops non-finite points, clamps pressure and line index', () {
      final decoded = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [
            Offset(double.nan, 0.2),
            Offset(0.2, double.infinity),
            Offset(0.5, 0.5),
          ],
          const [0.5, 0.5, double.nan],
          const [0, 1, 900],
        ),
      );
      expect(decoded.points, hasLength(3));
      expect(decoded.points[0], closeTo(0.5, 1e-6));
      expect(decoded.points[2], closeTo(1.0, 1e-6));
      expect(decoded.lineIndices, [255]);

      final clamped = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          const [-3, 7],
        ),
      ).points;
      expect(clamped[2], 0.0);
      expect(clamped[5], 1.0);
    });

    test('ignores a trailing partial record in either layout', () {
      final triples = InkCodec.encodePoints(const [Offset(0.5, 0.5)], const []);
      expect(
        InkCodec.decodePoints(Uint8List.fromList([...triples, 1, 2])).points,
        hasLength(3),
      );

      final quads = InkCodec.encodePoints(
        const [Offset(0.5, 0.5)],
        const [],
        const [1],
      );
      final padded = Uint8List.fromList([...quads, 1, 2, 3, 4, 5, 6, 7]);
      final decoded = InkCodec.decodePoints(padded);
      expect(decoded.points, hasLength(3));
      expect(decoded.lineIndices, [1]);
    });

    test('rejects an INK1 header with an unknown stride', () {
      final bytes = Uint8List(5 + 16)..setAll(0, [0x49, 0x4E, 0x4B, 0x31, 3]);
      expect(() => InkCodec.decodePoints(bytes), throwsFormatException);
    });
  });

  group('InkAnchor JSON', () {
    test('round-trips every kind with the rect as four numbers', () {
      for (final kind in InkAnchorKind.values) {
        final anchor = InkAnchor(
          kind: kind,
          chapter: 7,
          start: 11,
          end: 22,
          rect: const Rect.fromLTWH(1.5, -2, 30, 40),
        );
        final json = anchor.toJson();
        expect(json['rect'], [1.5, -2.0, 30.0, 40.0]);

        final restored = InkAnchor.fromJson(json);
        expect(restored.kind, kind);
        expect(restored.chapter, 7);
        expect(restored.start, 11);
        expect(restored.end, 22);
        expect(restored.rect, anchor.rect);
        expect(restored.lines, isEmpty);
      }
    });

    test('round-trips per-line rects and omits lines when absent', () {
      final anchor = InkAnchor(
        kind: InkAnchorKind.text,
        chapter: 2,
        start: 1,
        end: 4,
        rect: const Rect.fromLTWH(10, 20, 100, 60),
        lines: const [
          Rect.fromLTWH(10, 20, 100, 25),
          Rect.fromLTWH(10, 50, 90, 30),
        ],
      );
      final json = anchor.toJson();
      expect(json['lines'], [
        [10.0, 20.0, 100.0, 25.0],
        [10.0, 50.0, 90.0, 30.0],
      ]);
      final restored = InkAnchor.fromJson(json);
      expect(restored.lines, anchor.lines);
      expect(restored.rect, anchor.rect);

      final plain = InkAnchor(
        kind: InkAnchorKind.page,
        chapter: 0,
        rect: const Rect.fromLTWH(0, 0, 10, 10),
      );
      expect(plain.toJson().containsKey('lines'), isFalse);
      expect(InkAnchor.fromJson(plain.toJson()).lines, isEmpty);
    });

    test('start and end default when absent', () {
      final restored = InkAnchor.fromJson({
        'kind': 'page',
        'chapter': 0,
        'rect': [0, 0, 1, 1],
      });
      expect(restored.start, 0);
      expect(restored.end, 0);
    });

    test('rejects unknown kinds, bad rects and non-finite values', () {
      Map<String, Object?> valid() => {
        'kind': 'text',
        'chapter': 1,
        'start': 0,
        'end': 0,
        'rect': [0, 0, 10, 10],
      };

      expect(
        () => InkAnchor.fromJson({...valid(), 'kind': 'scribble'}),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'rect': [0, 0, 10],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'rect': [0, 0, double.nan, 10],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'rect': [0, 0, 10, 10, 1],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({...valid(), 'chapter': 'one'}),
        throwsFormatException,
      );
    });

    test('rejects negative rect dimensions', () {
      expect(
        () => InkAnchor.fromJson({
          'kind': 'text',
          'chapter': 1,
          'rect': [0, 0, -10, 10],
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed line geometry', () {
      Map<String, Object?> valid() => {
        'kind': 'text',
        'chapter': 1,
        'rect': [0, 0, 10, 10],
      };

      expect(
        () => InkAnchor.fromJson({...valid(), 'lines': 'two'}),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'lines': [
            [0, 0, 10],
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'lines': [
            [0, 0, double.nan, 10],
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'lines': [
            [0, 0, -10, 10],
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => InkAnchor.fromJson({
          ...valid(),
          'lines': [
            [0, 0, 10, 10],
            [0, 10, 10, 10],
          ],
        }),
        returnsNormally,
      );
    });
  });

  group('InkStroke geometry', () {
    test('pointLocal maps normalized points into the supplied rect', () {
      final stroke = buildStroke(const [
        Offset(0, 0),
        Offset(0.5, 0.5),
        Offset(1, 1),
        Offset(-0.1, 1.2),
      ]);

      expect(stroke.pointCount, 4);
      expect(stroke.pointLocal(0, anchorRect), const Offset(10, 20));
      expect(stroke.pointLocal(1, anchorRect), const Offset(60, 120));
      expect(stroke.pointLocal(2, anchorRect), const Offset(110, 220));
      expect(stroke.pointLocal(3, anchorRect).dx, closeTo(0, 1e-4));

      // A relaid-out anchor rect moves the drawing with it.
      const moved = Rect.fromLTWH(0, 0, 50, 100);
      expect(stroke.pointLocal(1, moved), const Offset(25, 50));
      expect(() => stroke.pointLocal(4, anchorRect), throwsRangeError);
    });

    test('boundsIn is the page-space box of the points', () {
      final stroke = buildStroke(const [Offset(0.25, 0.1), Offset(0.75, 0.6)]);
      final bounds = stroke.boundsIn(anchorRect);
      expect(bounds.left, closeTo(35, 1e-4));
      expect(bounds.top, closeTo(40, 1e-4));
      expect(bounds.right, closeTo(85, 1e-4));
      expect(bounds.bottom, closeTo(140, 1e-4));
    });

    test('an empty stroke has no points and a zero-size box', () {
      final stroke = buildStroke(const []);
      expect(stroke.pointCount, 0);
      expect(stroke.boundsIn(anchorRect), const Rect.fromLTWH(10, 20, 0, 0));
    });

    test('copyWith changes only the id and keeps line indices', () {
      final stroke = buildStroke(
        const [Offset(0.5, 0.5), Offset(0.25, 0.75)],
        lineIndices: const [0, 1],
      );
      final copy = stroke.copyWith(id: 42);
      expect(copy.id, 42);
      expect(copy.anchor, same(stroke.anchor));
      expect(copy.points, same(stroke.points));
      expect(copy.lineIndices, same(stroke.lineIndices));
      expect(copy.lineIndices, [0, 1]);
      expect(stroke.id, isNull);
    });

    test('rejects a point list that is not x, y, pressure triples', () {
      expect(
        () => InkStroke(
          anchor: const InkAnchor(
            kind: InkAnchorKind.text,
            chapter: 0,
            rect: anchorRect,
          ),
          color: 0,
          width: 1,
          points: Float32List(4),
        ),
        throwsArgumentError,
      );
    });

    test('rejects line indices that do not match the point count', () {
      expect(
        () => InkStroke(
          anchor: const InkAnchor(
            kind: InkAnchorKind.text,
            chapter: 0,
            rect: anchorRect,
          ),
          color: 0,
          width: 1,
          points: Float32List(3),
          lineIndices: Uint8List(2),
        ),
        throwsArgumentError,
      );
    });
  });

  group('per-line mapping', () {
    const storedLines = [
      Rect.fromLTWH(10, 20, 100, 10),
      Rect.fromLTWH(10, 40, 100, 10),
      Rect.fromLTWH(10, 60, 100, 10),
    ];
    InkStroke lined() => buildStroke(
      const [Offset(0, 0.5), Offset(0.5, 0.5), Offset(1, 0.5)],
      lines: storedLines,
      lineIndices: const [0, 1, 2],
    );

    test('uses the anchor rect when the layout has no lines', () {
      final stroke = buildStroke(const [Offset(0.5, 0.5)]);
      expect(
        inkPointInLines(stroke, 0, const []),
        stroke.pointLocal(0, anchorRect),
      );
    });

    test('maps every point into the first line when one line is stored', () {
      const current = [Rect.fromLTWH(0, 0, 80, 20)];
      final stroke = buildStroke(const [Offset(0, 0), Offset(1, 1)]);
      expect(inkPointInLines(stroke, 0, current), const Offset(0, 0));
      expect(inkPointInLines(stroke, 1, current), const Offset(80, 20));
    });

    test('maps each stored line onto an equal current line count', () {
      final stroke = lined();
      expect(inkPointInLines(stroke, 0, storedLines), const Offset(10, 25));
      expect(inkPointInLines(stroke, 1, storedLines), const Offset(60, 45));
      expect(inkPointInLines(stroke, 2, storedLines), const Offset(110, 65));
    });

    test('stretches stored lines onto an expanded line count', () {
      const current = [
        Rect.fromLTWH(0, 0, 100, 20),
        Rect.fromLTWH(0, 40, 100, 20),
        Rect.fromLTWH(0, 80, 100, 20),
        Rect.fromLTWH(0, 120, 100, 20),
        Rect.fromLTWH(0, 160, 100, 20),
      ];
      final stroke = lined();
      // Stored line 1 of 3 maps to fraction 2 of the 4 gaps: the third
      // current line.
      expect(inkPointInLines(stroke, 1, current), const Offset(50, 90));
      // Stored line 2 of 3 maps to fraction 1.0: the last current line.
      expect(inkPointInLines(stroke, 2, current), const Offset(100, 170));
    });

    test('squeezes stored lines onto a smaller line count', () {
      const current = [Rect.fromLTWH(0, 0, 50, 10)];
      final stroke = lined();
      expect(inkPointInLines(stroke, 0, current), const Offset(0, 5));
      expect(inkPointInLines(stroke, 1, current), const Offset(25, 5));
      expect(inkPointInLines(stroke, 2, current), const Offset(50, 5));
    });

    test('interpolates between the floor and ceil current lines', () {
      const current = [
        Rect.fromLTWH(0, 0, 100, 10),
        Rect.fromLTWH(0, 100, 100, 20),
      ];
      final stroke = lined();
      // 3 stored lines onto 2: stored line 1 maps to fraction 0.5 of the
      // rects, giving top 50 and height 15.
      final point = inkPointInLines(stroke, 1, current);
      expect(point.dx, closeTo(50, 1e-6));
      expect(point.dy, closeTo(50 + 0.5 * 15, 1e-6));
    });

    test('bounds span the mapped points across lines', () {
      const current = [
        Rect.fromLTWH(10, 20, 100, 10),
        Rect.fromLTWH(10, 40, 100, 10),
      ];
      final stroke = buildStroke(
        const [Offset(0, 0), Offset(1, 1)],
        lines: current,
        lineIndices: const [0, 1],
      );
      expect(
        inkBoundsInLines(stroke, current),
        const Rect.fromLTRB(10, 20, 110, 50),
      );

      final empty = buildStroke(const [], lines: current);
      expect(
        inkBoundsInLines(empty, current),
        const Rect.fromLTWH(10, 20, 0, 0),
      );
    });

    test('width scales with the current line height and clamps', () {
      final stroke = buildStroke(
        const [Offset(0.5, 0.5)],
        width: 2,
        lines: const [Rect.fromLTWH(0, 0, 100, 10)],
      );
      expect(
        inkWidthInLines(stroke, const [Rect.fromLTWH(0, 0, 100, 20)]),
        closeTo(4, 1e-6),
      );
      expect(
        inkWidthInLines(stroke, const [Rect.fromLTWH(0, 0, 100, 100)]),
        closeTo(6, 1e-6),
      );
      expect(
        inkWidthInLines(stroke, const [Rect.fromLTWH(0, 0, 100, 1)]),
        closeTo(1, 1e-6),
      );
      expect(inkWidthInLines(stroke, const []), closeTo(2, 1e-6));

      // Without stored lines the anchor rect is the stored line.
      final legacy = buildStroke(const [Offset(0.5, 0.5)], width: 2);
      expect(
        inkWidthInLines(legacy, const [Rect.fromLTWH(0, 0, 100, 100)]),
        closeTo(1, 1e-6),
      );
      expect(inkWidthInLines(legacy, const []), closeTo(2, 1e-6));
    });

    test('hit testing uses the mapped line position', () {
      const lines = [
        Rect.fromLTWH(0, 0, 100, 10),
        Rect.fromLTWH(0, 100, 100, 10),
      ];
      final stroke = buildStroke(
        const [Offset(0.5, 0.5), Offset(0.5, 0.5)],
        lines: lines,
        lineIndices: const [0, 1],
      );
      expect(inkStrokeHitLines(stroke, lines, const Offset(50, 5)), isTrue);
      expect(inkStrokeHitLines(stroke, lines, const Offset(50, 105)), isTrue);
      expect(inkStrokeHitLines(stroke, lines, const Offset(50, 60)), isTrue);
      expect(inkStrokeHitLines(stroke, lines, const Offset(0, 60)), isFalse);

      // The same stroke squeezed into one line sits entirely on it.
      const squeezed = [Rect.fromLTWH(0, 0, 100, 10)];
      expect(inkStrokeHitLines(stroke, squeezed, const Offset(50, 5)), isTrue);
      expect(
        inkStrokeHitLines(stroke, squeezed, const Offset(50, 105)),
        isFalse,
      );
    });
  });

  group('inkStrokeHit', () {
    InkStroke line({double width = 2}) =>
        buildStroke(const [Offset(0.1, 0.5), Offset(0.9, 0.5)], width: width);

    test('hits on the line and near the segment', () {
      // Page-space line runs from (20, 120) to (100, 120).
      expect(inkStrokeHit(line(), anchorRect, const Offset(60, 120)), isTrue);
      expect(inkStrokeHit(line(), anchorRect, const Offset(60, 123)), isTrue);
      // Five pixels past the end, inside the default radius of 6.
      expect(inkStrokeHit(line(), anchorRect, const Offset(105, 120)), isTrue);
    });

    test('misses far from the stroke', () {
      expect(inkStrokeHit(line(), anchorRect, const Offset(60, 160)), isFalse);
      expect(inkStrokeHit(line(), anchorRect, const Offset(60, 128)), isFalse);
    });

    test('the eraser radius widens the hit area', () {
      expect(
        inkStrokeHit(line(), anchorRect, const Offset(60, 129), radius: 10),
        isTrue,
      );
      expect(
        inkStrokeHit(line(), anchorRect, const Offset(60, 129), radius: 7),
        isFalse,
      );
    });

    test('the stroke width counts as part of the drawn band', () {
      const tolerancePoint = Offset(60, 136);
      expect(inkStrokeHit(line(width: 20), anchorRect, tolerancePoint), isTrue);
      expect(inkStrokeHit(line(width: 2), anchorRect, tolerancePoint), isFalse);
    });

    test('a dot hits only within its tolerance and an empty stroke never', () {
      final dot = buildStroke(const [Offset(0.5, 0.5)]);
      expect(inkStrokeHit(dot, anchorRect, const Offset(60, 120)), isTrue);
      expect(inkStrokeHit(dot, anchorRect, const Offset(80, 120)), isFalse);

      final empty = buildStroke(const []);
      expect(
        inkStrokeHit(empty, anchorRect, const Offset(10, 20), radius: 500),
        isFalse,
      );
    });

    test('follows a moved anchor rect', () {
      final stroke = line();
      const moved = Rect.fromLTWH(0, 0, 50, 100);
      expect(inkStrokeHit(stroke, moved, const Offset(25, 50)), isTrue);
      expect(inkStrokeHit(stroke, moved, const Offset(60, 120)), isFalse);
    });
  });
}

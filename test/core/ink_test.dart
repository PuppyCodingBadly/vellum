import 'dart:typed_data';
import 'dart:ui';

import 'package:test/test.dart';
import 'package:vellum/core/ink.dart';

void main() {
  const anchorRect = Rect.fromLTWH(10, 20, 100, 200);

  InkStroke buildStroke(
    List<Offset> points, {
    List<double> pressure = const <double>[],
    double width = 2,
    InkAnchorKind kind = InkAnchorKind.text,
    int chapter = 3,
    int start = 4,
    int end = 9,
    Rect rect = anchorRect,
  }) {
    return InkStroke(
      anchor: InkAnchor(
        kind: kind,
        chapter: chapter,
        start: start,
        end: end,
        rect: rect,
      ),
      color: 0xFF102030,
      width: width,
      points: Float32List.sublistView(InkCodec.encodePoints(points, pressure)),
    );
  }

  group('InkCodec', () {
    test('round-trips points and pressure through little-endian float32', () {
      final points = const [Offset(0, 0), Offset(0.5, 0.25), Offset(-0.1, 1.2)];
      final pressure = const [0.125, 0.5, 0.875];

      final encoded = InkCodec.encodePoints(points, pressure);
      expect(encoded, hasLength(points.length * 12));

      final decoded = InkCodec.decodePoints(encoded);
      expect(decoded, hasLength(9));
      for (var i = 0; i < points.length; i++) {
        expect(decoded[i * 3], closeTo(points[i].dx, 1e-6));
        expect(decoded[i * 3 + 1], closeTo(points[i].dy, 1e-6));
        expect(decoded[i * 3 + 2], closeTo(pressure[i], 1e-6));
      }
    });

    test('encode/decode leave an empty stroke empty', () {
      final encoded = InkCodec.encodePoints(const [], const []);
      expect(encoded, isEmpty);
      expect(InkCodec.decodePoints(encoded), isEmpty);
    });

    test('missing pressure becomes 1.0 and extra pressure is ignored', () {
      final decoded = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.2), Offset(0.3, 0.4)],
          const [0.25],
        ),
      );
      expect(decoded[2], closeTo(0.25, 1e-6));
      expect(decoded[5], closeTo(1.0, 1e-6));

      final ignored = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.2)],
          const [0.25, 0.75, 0.5],
        ),
      );
      expect(ignored, hasLength(3));
    });

    test('drops non-finite points, clamps pressure', () {
      final decoded = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [
            Offset(double.nan, 0.2),
            Offset(0.2, double.infinity),
            Offset(0.5, 0.5),
          ],
          const [0.5, 0.5, double.nan],
        ),
      );
      expect(decoded, hasLength(3));
      expect(decoded[0], closeTo(0.5, 1e-6));
      expect(decoded[2], closeTo(1.0, 1e-6));

      final clamped = InkCodec.decodePoints(
        InkCodec.encodePoints(
          const [Offset(0.1, 0.1), Offset(0.2, 0.2)],
          const [-3, 7],
        ),
      );
      expect(clamped[2], 0.0);
      expect(clamped[5], 1.0);
    });

    test('ignores a trailing partial triple', () {
      final encoded = InkCodec.encodePoints(const [Offset(0.5, 0.5)], const []);
      final truncated = Uint8List.fromList([...encoded, 1, 2]);
      expect(InkCodec.decodePoints(truncated), hasLength(3));
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
      }
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

    test('copyWith changes only the id', () {
      final stroke = buildStroke(const [Offset(0.5, 0.5)]);
      final copy = stroke.copyWith(id: 42);
      expect(copy.id, 42);
      expect(copy.anchor, same(stroke.anchor));
      expect(copy.points, same(stroke.points));
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

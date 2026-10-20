import 'package:test/test.dart';
import 'package:vellum/core/gestures.dart';

void main() {
  test('constants', () {
    expect(SWIPE_MIN_VELOCITY, 250.0);
    expect(SWIPE_DIRECTION_RATIO, 1.5);
  });

  test('swipe direction table', () {
    expect(swipeDirection(-800, 20), -1); // fast left → next page
    expect(swipeDirection(800, -20), 1); // fast right → previous page
    expect(swipeDirection(800, 900), 0); // too vertical
    expect(swipeDirection(-100, 0), 0); // too slow
    expect(swipeDirection(0, 800), 0); // pure vertical
  });

  test('custom min velocity', () {
    expect(swipeDirection(-100, 0, min: 50), -1);
    expect(swipeDirection(-100, 0, min: 200), 0);
  });
}

/// Swipe gesture classification for page turns.
///
/// Ports `vellum/core/gestures.py`.
library;

// Mirrors the Python constants (gestures.py) verbatim.
// ignore_for_file: constant_identifier_names

/// Minimum horizontal velocity (logical px/s) for a swipe.
const double SWIPE_MIN_VELOCITY = 250.0;

/// Horizontal swipe must exceed vertical by this ratio.
const double SWIPE_DIRECTION_RATIO = 1.5;

/// Classifies a fling velocity.
///
/// Returns -1 for a left swipe (next page), 1 for a right swipe (previous
/// page), or 0 when the gesture is too slow or too vertical.
int swipeDirection(double vx, double vy, {double min = SWIPE_MIN_VELOCITY}) {
  if (vx.abs() < min) return 0;
  if (vx.abs() < vy.abs() * SWIPE_DIRECTION_RATIO) return 0;
  return vx < 0 ? -1 : 1;
}

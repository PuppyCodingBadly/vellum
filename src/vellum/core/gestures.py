"""Pure helpers for touch gestures."""

from __future__ import annotations

SWIPE_MIN_VELOCITY = 250.0
SWIPE_DIRECTION_RATIO = 1.5


def swipe_direction(
    velocity_x: float,
    velocity_y: float,
    min_velocity: float = SWIPE_MIN_VELOCITY,
) -> int:
    """Return -1 for a left/next swipe, 1 for right/previous, else 0.

    Swipes must be fast enough and predominantly horizontal so vertical
    scrolling and text selection are not interpreted as page turns.
    """
    if abs(velocity_x) < min_velocity:
        return 0
    if abs(velocity_x) < abs(velocity_y) * SWIPE_DIRECTION_RATIO:
        return 0
    return -1 if velocity_x < 0 else 1

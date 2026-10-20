"""Tests for swipe direction decoding."""

from vellum.core.gestures import swipe_direction


def test_left_swipe_turns_next():
    assert swipe_direction(-800, 20) == -1


def test_right_swipe_turns_previous():
    assert swipe_direction(800, -20) == 1


def test_vertical_or_slow_swipes_are_ignored():
    assert swipe_direction(800, 900) == 0
    assert swipe_direction(-100, 0) == 0
    assert swipe_direction(0, 800) == 0

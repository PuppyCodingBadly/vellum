"""The time and cancellation one bridge request grants its plugin calls."""

from __future__ import annotations

import threading
import time


class DeadlineExceeded(TimeoutError):
    """The request's deadline passed before a plugin call could run."""


class Budget:
    """One monotonic deadline and one abort flag, shared by a request.

    A metadata search fans out to every loaded plugin; they all draw from
    the same budget, so N plugins cannot take N × timeout.  ``abort`` is
    handed to plugins that poll it for cancellation (calibre's
    ``identify``/``download_cover``), so expiry stops cooperative work
    instead of waiting for a call the caller already abandoned.
    """

    def __init__(self, timeout: float | None = None,
                 abort: threading.Event | None = None):
        self.timeout = timeout
        self.abort = abort if abort is not None else threading.Event()
        self._deadline = (None if timeout is None
                          else time.monotonic() + max(0.0, float(timeout)))

    def remaining(self) -> float | None:
        """Seconds left, or ``None`` when the request has no deadline."""
        if self._deadline is None:
            return None
        return max(0.0, self._deadline - time.monotonic())

    def grant(self, default: float) -> float:
        """The timeout for the next plugin call: what is left, else ``default``.

        Raises DeadlineExceeded (and sets abort) when the budget is spent,
        so no call starts that is already known to be abandoned.
        """
        left = self.remaining()
        if left == 0.0:
            self.abort.set()
            raise DeadlineExceeded(f"request deadline of {self.timeout}s exceeded")
        return default if left is None else left


def plugin_timeout(budget: Budget | None, default: float) -> float:
    """The timeout for one plugin call, inside or outside the protocol.

    ``None`` means the adapter was called directly; its documented default
    applies.  Expired budgets raise instead of returning another full slice.
    """
    return default if budget is None else budget.grant(default)


def plugin_abort(budget: Budget | None) -> threading.Event:
    """The cancellation flag for one plugin call."""
    return budget.abort if budget is not None else threading.Event()

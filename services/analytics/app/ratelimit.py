"""Rate limiting for the event intake (C-007, 429).

The contract puts the throttle at the gateway. The intake applies the same
fixed-window counter as its own defence, so a directly-addressed instance still
refuses a flood; a Redis-backed counter replaces it behind the same port when
the cache ships.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Protocol


class RateLimiter(Protocol):
    """Decides whether a caller may make another request."""

    async def allow(self, key: str) -> bool: ...


class InMemoryFixedWindowRateLimiter:
    """A per-key fixed-window counter held in memory."""

    def __init__(
        self,
        *,
        limit: int,
        window_seconds: int,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._limit = max(limit, 1)
        self._window_seconds = max(window_seconds, 1)
        self._clock = clock
        self._windows: dict[str, tuple[int, int]] = {}

    async def allow(self, key: str) -> bool:
        now = self._clock()
        window = int(now // self._window_seconds)
        current = self._windows.get(key)
        if current is None or current[0] != window:
            self._windows[key] = (window, 1)
            return True
        if current[1] >= self._limit:
            return False
        self._windows[key] = (window, current[1] + 1)
        return True

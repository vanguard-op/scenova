"""A minimal circuit breaker for the external model provider.

The architecture wraps the provider in a circuit breaker: when it is open the
product stops starting new generations instead of queueing calls that will
fail. The breaker is closed until `failure_threshold` consecutive failures are
recorded, then open for `reset_seconds` before a single trial is allowed.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass, field


@dataclass(slots=True)
class CircuitBreaker:
    failure_threshold: int
    reset_seconds: float
    clock: Callable[[], float] = field(default=time.monotonic)
    _failures: int = 0
    _opened_at: float | None = None

    def allow(self) -> bool:
        """Return True when a call may be attempted."""

        if self._opened_at is None:
            return True
        return self.clock() - self._opened_at >= self.reset_seconds

    def record_success(self) -> None:
        self._failures = 0
        self._opened_at = None

    def record_failure(self) -> None:
        self._failures += 1
        if self._failures >= self.failure_threshold:
            self._opened_at = self.clock()

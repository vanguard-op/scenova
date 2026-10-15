"""Rate limiting for the gateway's client routes (C-001).

The fixed-window counters live in Redis, not in the gateway's process memory
(architecture.md "Data Stores": the in-memory cache holds the rate-limit
counters). Redis keeps the count across every gateway replica, so the limit
holds however many instances serve the traffic — 5,000 concurrent readers scale
the replicas, not the allowance (nfr.md "Throughput & Capacity").

Each limiter still keeps an in-memory counter of its own as its fallback: when
Redis cannot be reached, the gateway stays available and limits per instance
until the cache returns, rather than refusing a reader a lookup the product
promises to serve (nfr.md "Degradation when a dependency fails"). The fallback
is retried against Redis on a short cooldown, so an outage costs a bounded
loosening of the cap, not a flap of reconnections on every request.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from typing import Any, Protocol, cast

from redis import asyncio as aioredis

logger = logging.getLogger(__name__)

# How long a limiter that saw Redis fail serves from its in-memory counter
# before it tries the cache again. Short enough that a cache restart is picked
# up quickly, long enough that the cooldown is not a per-request reconnect.
_REDIS_RETRY_SECONDS = 5.0


class RateLimiter(Protocol):
    """Decides whether a caller may make another request."""

    async def allow(self, key: str) -> bool: ...


class AsyncRedisLike(Protocol):
    """The commands the limiter drives on the async Redis client."""

    async def incr(self, key: str) -> int: ...

    async def expire(self, key: str, seconds: int) -> Any: ...

    async def aclose(self) -> None: ...


class InMemoryFixedWindowRateLimiter:
    """A per-key fixed-window counter held in this process's memory.

    Doubles as the fallback of the Redis limiter, so the deployment keeps
    limiting per instance while the cache is unreachable.
    """

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


class RedisFixedWindowRateLimiter:
    """A fixed-window counter held in Redis, shared by every gateway replica.

    The counter is one key per caller, incremented on each request and given its
    window's expiry on the first increment, so a window lasts `window_seconds`
    from the caller's first request within it, whatever replica served it.
    """

    def __init__(
        self,
        *,
        client: AsyncRedisLike,
        prefix: str,
        limit: int,
        window_seconds: int,
        clock: Callable[[], float] = time.monotonic,
        fallback: InMemoryFixedWindowRateLimiter | None = None,
    ) -> None:
        self._client = client
        self._prefix = f"ratelimit:{prefix}"
        self._limit = max(limit, 1)
        self._window_seconds = max(window_seconds, 1)
        self._clock = clock
        self._fallback = fallback or InMemoryFixedWindowRateLimiter(
            limit=self._limit,
            window_seconds=self._window_seconds,
            clock=clock,
        )
        self._retry_sat = -1.0
        self._degraded = False

    async def allow(self, key: str) -> bool:
        if self._clock() >= self._retry_sat:
            try:
                redis_key = f"{self._prefix}:{key}"
                count = await self._client.incr(redis_key)
                if count == 1:
                    await self._client.expire(redis_key, self._window_seconds)
            except Exception:
                # Any fault in the side-cache degrades to the in-memory
                # fallback rather than failing the request it was checking
                # (nfr.md "Degradation when a dependency fails"). Cancellation
                # is not caught: an aborted request must stay aborted.
                self._degraded = True
                self._retry_sat = self._clock() + _REDIS_RETRY_SECONDS
                logger.warning(
                    "the rate-limit cache is unreachable; limiting per instance until it returns"
                )
            else:
                if self._degraded:
                    logger.info("the rate-limit cache is reachable again")
                    self._degraded = False
                self._retry_sat = -1.0
                return count <= self._limit
        return await self._fallback.allow(key)


def build_redis_client(url: str) -> AsyncRedisLike:
    """Build the shared async Redis client the limiters drive.

    The client connects lazily: no request to a location with the cache down is
    failed by building it, and the limiters degrade to their in-memory fallback
    until the cache answers.
    """

    return cast(
        AsyncRedisLike,
        aioredis.Redis.from_url(url, socket_connect_timeout=2.0, socket_timeout=2.0),
    )

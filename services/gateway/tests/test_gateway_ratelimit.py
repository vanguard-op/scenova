"""Rate limiter tests."""

from __future__ import annotations

import pytest

from gateway.app.config import Settings
from gateway.app.ratelimit import (
    AsyncRedisLike,
    InMemoryFixedWindowRateLimiter,
    RedisFixedWindowRateLimiter,
)

_WINDOW = 60


class FakeRedis:
    """A stand-in for the async Redis client the Redis limiter drives."""

    def __init__(self, failure: Exception | None = None) -> None:
        self._failure = failure
        self.counts: dict[str, int] = {}
        self.expiries: dict[str, int] = {}
        self.closed = False

    async def incr(self, key: str) -> int:
        if self._failure is not None:
            raise self._failure
        self.counts[key] = self.counts.get(key, 0) + 1
        return self.counts[key]

    async def expire(self, key: str, seconds: int) -> bool:
        if self._failure is not None:
            raise self._failure
        self.expiries[key] = seconds
        return True

    async def aclose(self) -> None:
        self.closed = True


class RecoveringRedis(FakeRedis):
    """Fails until it recovers, as a restart of the cache would."""

    def recover(self) -> None:
        self._failure = None
        self.counts.clear()


@pytest.mark.asyncio
async def test_redis_limiter_allows_up_to_the_limit_then_blocks_shared_by_replicas() -> None:
    redis: AsyncRedisLike = FakeRedis()
    replica_a = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=2, window_seconds=_WINDOW
    )
    replica_b = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=2, window_seconds=_WINDOW
    )

    assert await replica_a.allow("reader") is True
    assert await replica_b.allow("reader") is True
    assert await replica_a.allow("reader") is False


@pytest.mark.asyncio
async def test_redis_limiter_gives_the_counter_its_window_expiry_on_first_increment() -> None:
    redis = FakeRedis()
    limiter = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=5, window_seconds=_WINDOW
    )

    assert await limiter.allow("reader") is True
    assert redis.expiries["ratelimit:lookup:reader"] == _WINDOW

    await limiter.allow("reader")
    assert redis.expiries["ratelimit:lookup:reader"] == _WINDOW


@pytest.mark.asyncio
async def test_redis_limiter_scopes_the_counter_by_prefix() -> None:
    redis = FakeRedis()
    lookups = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=1, window_seconds=_WINDOW
    )
    events = RedisFixedWindowRateLimiter(
        client=redis, prefix="events", limit=1, window_seconds=_WINDOW
    )

    assert await lookups.allow("reader") is True
    assert await lookups.allow("reader") is False
    assert await events.allow("reader") is True
    assert await events.allow("reader") is False


@pytest.mark.asyncio
async def test_redis_limiter_falls_back_to_memory_while_the_cache_is_unreachable() -> None:
    redis = FakeRedis(ConnectionError("cache down"))
    limiter = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=2, window_seconds=_WINDOW
    )

    assert await limiter.allow("reader") is True
    assert await limiter.allow("reader") is True
    assert await limiter.allow("reader") is False


@pytest.mark.asyncio
async def test_redis_limiter_serves_each_instance_from_its_own_counter_while_degraded() -> None:
    redis = FakeRedis(ConnectionError("cache down"))
    replica_a = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=1, window_seconds=_WINDOW
    )
    replica_b = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=1, window_seconds=_WINDOW
    )

    assert await replica_a.allow("reader") is True
    assert await replica_a.allow("reader") is False
    assert await replica_b.allow("reader") is True


@pytest.mark.asyncio
async def test_redis_limiter_does_not_reconnect_every_request_while_degraded() -> None:
    redis = FakeRedis(ConnectionError("cache down"))
    now = [0.0]
    limiter = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=1, window_seconds=_WINDOW, clock=lambda: now[0]
    )

    assert await limiter.allow("reader") is True
    assert await limiter.allow("reader") is False

    now[0] = 1.0
    assert await limiter.allow("reader") is False
    assert not redis.counts


@pytest.mark.asyncio
async def test_redis_limiter_resumes_the_cache_after_the_cooldown() -> None:
    redis = RecoveringRedis(ConnectionError("cache down"))
    now = [0.0]
    limiter = RedisFixedWindowRateLimiter(
        client=redis, prefix="lookup", limit=2, window_seconds=_WINDOW, clock=lambda: now[0]
    )

    assert await limiter.allow("reader") is True

    redis.recover()
    now[0] = 10.0
    assert await limiter.allow("reader") is True
    assert await limiter.allow("reader") is True
    assert await limiter.allow("reader") is False
    assert redis.counts["ratelimit:lookup:reader"] == 3


@pytest.mark.asyncio
async def test_in_memory_limiter_allows_up_to_the_limit_then_blocks() -> None:
    limiter = InMemoryFixedWindowRateLimiter(limit=2, window_seconds=60, clock=lambda: 0.0)

    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is False
    assert await limiter.allow("b") is True


@pytest.mark.asyncio
async def test_in_memory_limiter_resets_in_the_next_window() -> None:
    now = [0.0]
    limiter = InMemoryFixedWindowRateLimiter(limit=1, window_seconds=60, clock=lambda: now[0])

    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is False

    now[0] = 61.0
    assert await limiter.allow("a") is True


def test_settings_reads_the_cache_url_from_the_environment() -> None:
    assert (
        Settings.from_env({"REDIS_URL": "redis://cache:6379/0"}).redis_url == "redis://cache:6379/0"
    )
    assert Settings.from_env({"REDIS_URL": ""}).redis_url is None
    assert Settings.from_env({}).redis_url is None

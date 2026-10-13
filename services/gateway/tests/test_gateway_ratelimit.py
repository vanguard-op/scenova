"""Rate limiter tests."""

from __future__ import annotations

import pytest

from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter


@pytest.mark.asyncio
async def test_limiter_allows_up_to_the_limit_then_blocks() -> None:
    limiter = InMemoryFixedWindowRateLimiter(limit=2, window_seconds=60, clock=lambda: 0.0)

    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is False
    assert await limiter.allow("b") is True


@pytest.mark.asyncio
async def test_limiter_resets_in_the_next_window() -> None:
    now = [0.0]
    limiter = InMemoryFixedWindowRateLimiter(limit=1, window_seconds=60, clock=lambda: now[0])

    assert await limiter.allow("a") is True
    assert await limiter.allow("a") is False

    now[0] = 61.0
    assert await limiter.allow("a") is True

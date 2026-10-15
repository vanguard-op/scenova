"""Client tests for the lookup path's allowance meter (FEAT-013)."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from lookup.app.entitlement import (
    EntitlementUnavailableError,
    HttpEntitlement,
    SpendOutcome,
)


def _body(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "allowed": True,
        "plan": "free",
        "lookupsUsed": 1,
        "lookupsLimit": 20,
        "periodEnd": "2026-11-15T12:00:00+00:00",
    }
    body.update(overrides)
    return body


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpEntitlement:
    return HttpEntitlement(
        base_url="http://entitlement",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_a_spend_posts_the_subject_and_idempotency_key() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(200, json=_body())

    client = _client(handler)
    outcome = await client.spend("reader-1", "lk_1")

    assert seen["path"] == "/internal/entitlements/spend"
    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {"subject": "reader-1", "clientLookupId": "lk_1"}
    assert outcome == SpendOutcome(
        allowed=True,
        lookups_used=1,
        lookups_limit=20,
        period_end="2026-11-15T12:00:00+00:00",
    )
    await client.aclose()


@pytest.mark.asyncio
async def test_a_spent_allowance_is_reported() -> None:
    client = _client(
        lambda _request: httpx2.Response(
            200, json=_body(allowed=False, lookupsUsed=20, lookupsLimit=20)
        )
    )

    outcome = await client.spend("reader-1", "lk_1")

    assert outcome.allowed is False
    assert outcome.lookups_used == outcome.lookups_limit == 20
    await client.aclose()


@pytest.mark.asyncio
async def test_a_refused_spend_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(401, json={"code": "unauthorized"}))

    with pytest.raises(EntitlementUnavailableError):
        await client.spend("reader-1", "lk_1")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unreadable_answer_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(200, json={"allowed": True}))

    with pytest.raises(EntitlementUnavailableError):
        await client.spend("reader-1", "lk_1")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unreachable_meter_is_treated_as_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("down")

    client = _client(handler)

    with pytest.raises(EntitlementUnavailableError):
        await client.spend("reader-1", "lk_1")
    await client.aclose()

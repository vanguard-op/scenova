"""The gateway's service identity for its calls to the internal services.

Every service behind the gateway is internal only, so Cloud Run checks the
caller's identity at the platform edge. The gateway mints an ID token for its own
runtime service account and presents it on `X-Serverless-Authorization`, leaving
the caller's own `Authorization` header for the service behind the edge to decide
(architecture.md "Component: API Gateway"; nfr.md NFR-020).
"""

from __future__ import annotations

import httpx2
import pytest

from gateway.app.entitlement_client import HttpEntitlementClient
from gateway.app.service_identity import (
    SERVERLESS_AUTHORIZATION_HEADER,
    ServiceIdentity,
)


def test_the_identity_stands_down_outside_a_deployed_service() -> None:
    # No platform edge to satisfy on a laptop or in the unit tests, so no token is
    # minted and no header is added.
    identity = ServiceIdentity(
        "https://entitlement.example",
        enabled=False,
        fetch=lambda audience: pytest.fail("a token must not be minted"),
    )

    assert identity.headers() == {}


def test_the_identity_presents_a_bearer_token_for_its_audience() -> None:
    audiences: list[str] = []

    def fetch(audience: str) -> str:
        audiences.append(audience)
        return "id-token"

    identity = ServiceIdentity(
        "https://entitlement.example/",
        enabled=True,
        fetch=fetch,
        clock=lambda: 0.0,
    )

    assert identity.headers() == {SERVERLESS_AUTHORIZATION_HEADER: "Bearer id-token"}
    # The audience is the service being called, and the trailing slash is dropped.
    assert audiences == ["https://entitlement.example"]


def test_the_identity_caches_the_token_until_it_nears_expiry() -> None:
    now = {"value": 0.0}
    calls: list[str] = []

    def fetch(audience: str) -> str:
        calls.append(audience)
        return f"token-{len(calls)}"

    identity = ServiceIdentity(
        "https://entitlement.example",
        enabled=True,
        fetch=fetch,
        clock=lambda: now["value"],
        ttl_seconds=100.0,
    )

    assert identity.headers()[SERVERLESS_AUTHORIZATION_HEADER] == "Bearer token-1"
    now["value"] = 99.0
    assert identity.headers()[SERVERLESS_AUTHORIZATION_HEADER] == "Bearer token-1"
    now["value"] = 100.0
    assert identity.headers()[SERVERLESS_AUTHORIZATION_HEADER] == "Bearer token-2"
    assert len(calls) == 2


def test_a_mint_that_fails_leaves_the_call_to_the_service_to_refuse() -> None:
    # A metadata outage must not fail the call outright: the service behind the
    # edge refuses the unauthenticated call, which is the honest answer.
    def fetch(audience: str) -> str:
        raise ValueError("no metadata server")

    identity = ServiceIdentity("https://entitlement.example", enabled=True, fetch=fetch)

    assert identity.headers() == {}


@pytest.mark.asyncio
async def test_the_sync_call_carries_the_identity_and_the_webhook_authorization() -> None:
    # The two headers are distinct: the identity authorizes the gateway to Cloud
    # Run, and the webhook's own Authorization is what the entitlement service
    # checks (C-019). The body is forwarded unread.
    seen: dict[str, str] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["url"] = str(request.url)
        seen["identity"] = request.headers.get(SERVERLESS_AUTHORIZATION_HEADER, "")
        seen["authorization"] = request.headers.get("authorization", "")
        seen["body"] = request.content.decode()
        return httpx2.Response(202, json={"applied": True})

    identity = ServiceIdentity(
        "https://entitlement.example",
        enabled=True,
        fetch=lambda audience: "id-token",
        clock=lambda: 0.0,
    )
    client = HttpEntitlementClient(
        base_url="https://entitlement.example",
        identity=identity,
        transport=httpx2.MockTransport(handler),
    )
    try:
        response = await client.sync_entitlement(
            b'{"accountId":"reader-1"}', "processor-secret", "corr-1"
        )
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert seen["url"] == "https://entitlement.example/internal/entitlements/sync"
    assert seen["identity"] == "Bearer id-token"
    assert seen["authorization"] == "processor-secret"
    assert seen["body"] == '{"accountId":"reader-1"}'

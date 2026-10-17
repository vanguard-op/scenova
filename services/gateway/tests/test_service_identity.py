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

from gateway.app import service_identity
from gateway.app.analytics_client import HttpAnalyticsClient
from gateway.app.entitlement_client import HttpEntitlementClient
from gateway.app.feedback_client import HttpFeedbackClient
from gateway.app.lookup_client import HttpLookupClient
from gateway.app.notification_client import HttpPushRegistrationClient
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


# --- Every client asserts the identity to its own service --------------------
#
# The entitlement client above is one of five. Each of the others reaches its own
# internal service through the same edge, so each must mint its token for that
# service's address and present it on every call it makes — the reader routes,
# the operator review routes, and the service-to-service anonymize seams alike
# (architecture.md "Component: API Gateway"; nfr.md NFR-020).


class _CapturedRequest:
    """The request a client sent, for the assertions below."""

    def __init__(self) -> None:
        self.url = ""
        self.identity = ""
        self.authorization = ""
        self.internal_audience = ""
        self.body = ""

    def handle(self, request: httpx2.Request) -> httpx2.Response:
        self.url = str(request.url)
        self.identity = request.headers.get(SERVERLESS_AUTHORIZATION_HEADER, "")
        self.authorization = request.headers.get("authorization", "")
        self.internal_audience = request.headers.get("x-internal-audience", "")
        self.body = request.content.decode()
        return httpx2.Response(202, json={"ok": True})


def _enable_identity(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Let the client mint through its real path, recording the audience.

    Cloud Run sets K_SERVICE on every instance it starts, which is what turns the
    identity on. The token fetch is stubbed so the test never reaches the metadata
    server, but the audience the client mints for is the one it really uses.
    """

    audiences: list[str] = []

    def fetch(audience: str) -> str:
        audiences.append(audience)
        return "id-token"

    monkeypatch.setenv("K_SERVICE", "gateway")
    monkeypatch.setattr(service_identity, "_fetch_id_token", fetch)
    return audiences


@pytest.mark.asyncio
async def test_the_lookup_client_carries_the_identity_for_the_lookup_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpLookupClient(
        base_url="https://lookup.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.create_lookup({"selection": "coming"}, "corr-2")
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://lookup.example/internal/lookups"
    assert captured.identity == "Bearer id-token"
    # An internal call carries the internal audience the service checks, not a
    # reader token.
    assert captured.internal_audience == "scenova-internal"
    assert captured.authorization == ""
    # The token is minted for the lookup service, the address Cloud Run binds it to.
    assert audiences == ["https://lookup.example"]


@pytest.mark.asyncio
async def test_the_analytics_client_carries_the_identity_for_the_analytics_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpAnalyticsClient(
        base_url="https://analytics.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.ingest({"events": []}, "Bearer reader-token", "corr-3")
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://analytics.example/v1/events"
    assert captured.identity == "Bearer id-token"
    # The identity authorizes the gateway to the edge; the reader's own token is
    # still what the intake resolves the subject from.
    assert captured.authorization == "Bearer reader-token"
    assert audiences == ["https://analytics.example"]


@pytest.mark.asyncio
async def test_the_push_client_carries_the_identity_for_the_notification_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpPushRegistrationClient(
        base_url="https://notification.example",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.register({"token": "push-token"}, "Bearer reader-token", "corr-4")
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://notification.example/v1/push-registrations"
    assert captured.identity == "Bearer id-token"
    assert captured.authorization == "Bearer reader-token"
    assert audiences == ["https://notification.example"]


@pytest.mark.asyncio
async def test_the_feedback_client_carries_the_identity_for_the_feedback_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpFeedbackClient(
        base_url="https://feedback.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.record_feedback(
            {"lookupId": "lk_1"}, "Bearer reader-token", "corr-5"
        )
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://feedback.example/v1/feedback"
    assert captured.identity == "Bearer id-token"
    assert captured.authorization == "Bearer reader-token"
    assert audiences == ["https://feedback.example"]


@pytest.mark.asyncio
async def test_the_review_call_carries_the_identity_and_the_operator_token(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpFeedbackClient(
        base_url="https://feedback.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.review(
            "GET",
            "/internal/review/queue",
            params={"page": "1"},
            body=None,
            authorization="Bearer operator-token",
            correlation_id="corr-6",
        )
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://feedback.example/internal/review/queue?page=1"
    assert captured.identity == "Bearer id-token"
    # The operator's session is forwarded unchanged, so the review service
    # re-checks the same curator role the gateway did.
    assert captured.authorization == "Bearer operator-token"
    assert audiences == ["https://feedback.example"]


@pytest.mark.asyncio
async def test_the_analytics_anonymize_seam_carries_the_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A deletion erases the reader's events through the intake's seam, reached
    # with the gateway's own identity and the internal audience — never the
    # reader's token, which the deletion has already invalidated (nfr.md
    # "Privacy & Compliance").
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpAnalyticsClient(
        base_url="https://analytics.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.anonymize_subject("reader-1", "corr-7")
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://analytics.example/internal/events/anonymize"
    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert captured.authorization == ""
    assert audiences == ["https://analytics.example"]


@pytest.mark.asyncio
async def test_the_feedback_anonymize_seam_carries_the_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _CapturedRequest()
    client = HttpFeedbackClient(
        base_url="https://feedback.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        response = await client.anonymize_subject("reader-1", "corr-8")
    finally:
        await client.aclose()

    assert response.status_code == 202
    assert captured.url == "https://feedback.example/internal/feedback/anonymize"
    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert captured.authorization == ""
    assert audiences == ["https://feedback.example"]

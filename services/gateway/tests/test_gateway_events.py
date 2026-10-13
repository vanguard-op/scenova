"""Client API tests for the gateway's event intake (C-007 status and shape mapping).

The gateway authenticates and rate-limits the batch, validates the envelope, and
forwards the caller's token to the analytics intake, whose taxonomy and
personal-data rejections pass back through unchanged.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.analytics_client import AnalyticsClient
from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier, Subject, TokenVerifier
from gateway.app.config import Settings
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.lookup_client import LookupClient, UpstreamResponse
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_AUTH = {"Authorization": "Bearer dev:reader-1"}


class _Verifier:
    async def verify(self, authorization: str | None) -> Subject:
        return Subject(id="reader-1")


class _FakeAnalyticsClient:
    def __init__(
        self,
        *,
        status_code: int = 202,
        body: bytes = b'{"accepted":1}',
        error: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.error = error
        self.last_payload: Mapping[str, Any] | None = None
        self.last_authorization: str | None = None

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_payload = payload
        self.last_authorization = authorization
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _FakeLookupClient:
    def __init__(self) -> None:
        self.calls = 0

    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        self.calls += 1
        return UpstreamResponse(
            status_code=200, body=b'{"lookupId":"lk_1"}', content_type="application/json"
        )

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"lookupId":"lk_1"}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


def _client(
    analytics: AnalyticsClient,
    *,
    verifier: TokenVerifier | None = None,
    lookup_client: LookupClient | None = None,
    lookup_rate_limit: int = 120,
    events_rate_limit: int = 120,
) -> TestClient:
    app = create_app(
        settings=Settings(),
        verifier=verifier or _Verifier(),
        limiter=InMemoryFixedWindowRateLimiter(
            limit=lookup_rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
        event_limiter=InMemoryFixedWindowRateLimiter(
            limit=events_rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
        lookup_client=lookup_client or _FakeLookupClient(),
        analytics_client=analytics,
    )
    return TestClient(app)


def _event(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "eventId": "evt-1",
        "name": "lookup_started",
        "occurredAt": "2026-10-13T12:00:00Z",
        "anonymousId": "anon-1",
        "sessionId": "sess-1",
        "platform": "android",
        "appVersion": "1.0.0+1",
        "locale": "en",
        "properties": {"kind": "word", "source": "typed"},
    }
    body.update(overrides)
    return body


def test_a_missing_token_is_unauthorized() -> None:
    with _client(_FakeAnalyticsClient(), verifier=DevTokenVerifier()) as client:
        response = client.post("/v1/events", json={"events": [_event()]})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_a_valid_batch_passes_through_with_the_caller_token() -> None:
    analytics = _FakeAnalyticsClient()
    with _client(analytics) as client:
        response = client.post(
            "/v1/events",
            json={"events": [_event()]},
            headers={**_AUTH, "x-correlation-id": "corr-1"},
        )

    assert response.status_code == 202
    assert response.json() == {"accepted": 1}
    assert response.headers["x-correlation-id"] == "corr-1"
    assert analytics.last_payload == {"events": [_event()]}
    assert analytics.last_authorization == _AUTH["Authorization"]


def test_a_batch_over_fifty_is_rejected() -> None:
    events = [_event(eventId=f"evt-{index}") for index in range(51)]
    with _client(_FakeAnalyticsClient()) as client:
        response = client.post("/v1/events", json={"events": events}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_malformed_event_is_rejected() -> None:
    with _client(_FakeAnalyticsClient()) as client:
        response = client.post(
            "/v1/events", json={"events": [{"name": "lookup_started"}]}, headers=_AUTH
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_platform_is_rejected() -> None:
    with _client(_FakeAnalyticsClient()) as client:
        response = client.post(
            "/v1/events", json={"events": [_event(platform="web")]}, headers=_AUTH
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_intake_rejection_passes_through() -> None:
    analytics = _FakeAnalyticsClient(
        status_code=400, body=b'{"code":"personal_data","message":"no"}'
    )
    with _client(analytics) as client:
        response = client.post("/v1/events", json={"events": [_event()]}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "personal_data"


def test_a_flood_is_rate_limited() -> None:
    with _client(_FakeAnalyticsClient(), events_rate_limit=1) as client:
        first = client.post("/v1/events", json={"events": [_event()]}, headers=_AUTH)
        second = client.post(
            "/v1/events", json={"events": [_event(eventId="evt-2")]}, headers=_AUTH
        )

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"


def test_an_unavailable_intake_is_a_service_unavailable() -> None:
    analytics = _FakeAnalyticsClient(error=UpstreamUnavailableError("down"))
    with _client(analytics) as client:
        response = client.post("/v1/events", json={"events": [_event()]}, headers=_AUTH)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"


def test_the_event_budget_is_separate_from_the_lookup_budget() -> None:
    # A caller that has spent its lookup budget can still send events; the two
    # are counted apart so a busy reading session does not throttle telemetry.
    lookup = _FakeLookupClient()
    with _client(
        _FakeAnalyticsClient(), lookup_client=lookup, lookup_rate_limit=1, events_rate_limit=5
    ) as client:
        first = client.post(
            "/v1/lookups",
            json={
                "selection": "coming",
                "clientLookupId": "c-1",
                "platform": "android",
                "locale": "en",
                "consentModelProcessing": True,
            },
            headers=_AUTH,
        )
        second = client.post(
            "/v1/lookups",
            json={
                "selection": "going",
                "clientLookupId": "c-2",
                "platform": "android",
                "locale": "en",
                "consentModelProcessing": True,
            },
            headers=_AUTH,
        )
        events = client.post("/v1/events", json={"events": [_event()]}, headers=_AUTH)

    assert first.status_code == 200
    assert second.status_code == 429
    assert events.status_code == 202

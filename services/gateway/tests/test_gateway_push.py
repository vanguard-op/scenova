"""Client API tests for the gateway's push-registration route (C-008).

The gateway authenticates and rate-limits the intake and forwards the caller's
token to the notification service, whose lookup-ownership and token checks pass
back through unchanged.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier, Subject, TokenVerifier
from gateway.app.config import Settings
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.lookup_client import LookupClient, UpstreamResponse
from gateway.app.notification_client import PushRegistrationClient
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_AUTH = {"Authorization": "Bearer dev:reader-1"}

_VALID = {"token": "fcm-token-1", "platform": "android", "lookupId": "lk_1"}


class _Verifier:
    async def verify(self, authorization: str | None) -> Subject:
        return Subject(id="reader-1")


class _FakeNotificationClient:
    def __init__(
        self,
        *,
        status_code: int = 202,
        body: bytes = b'{"registered":true}',
        error: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.error = error
        self.last_payload: Mapping[str, Any] | None = None
        self.last_authorization: str | None = None

    async def register(
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
    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
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
    notification: PushRegistrationClient,
    *,
    verifier: TokenVerifier | None = None,
    lookup_client: LookupClient | None = None,
    lookup_rate_limit: int = 120,
    registration_rate_limit: int = 120,
) -> TestClient:
    app = create_app(
        settings=Settings(),
        verifier=verifier or _Verifier(),
        limiter=InMemoryFixedWindowRateLimiter(
            limit=lookup_rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
        registration_limiter=InMemoryFixedWindowRateLimiter(
            limit=registration_rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
        lookup_client=lookup_client or _FakeLookupClient(),
        notification_client=notification,
    )
    return TestClient(app)


def test_a_missing_token_is_unauthorized() -> None:
    with _client(_FakeNotificationClient(), verifier=DevTokenVerifier()) as client:
        response = client.post("/v1/push-registrations", json=_VALID)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_a_registration_passes_through_with_the_caller_token() -> None:
    notification = _FakeNotificationClient()
    with _client(notification) as client:
        response = client.post(
            "/v1/push-registrations",
            json=_VALID,
            headers={**_AUTH, "x-correlation-id": "corr-1"},
        )

    assert response.status_code == 202
    assert response.json() == {"registered": True}
    assert response.headers["x-correlation-id"] == "corr-1"
    assert notification.last_payload == _VALID
    assert notification.last_authorization == _AUTH["Authorization"]


def test_an_unknown_platform_is_a_bad_request() -> None:
    with _client(_FakeNotificationClient()) as client:
        response = client.post(
            "/v1/push-registrations", json={**_VALID, "platform": "web"}, headers=_AUTH
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_registration_without_a_lookup_is_a_bad_request() -> None:
    # C-008 requires the lookup the reader is waiting on: without it the notice
    # has nothing to find its way back to.
    body = {"token": "fcm-token-1", "platform": "android"}
    with _client(_FakeNotificationClient()) as client:
        response = client.post("/v1/push-registrations", json=body, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_registration_with_an_extra_field_is_rejected() -> None:
    with _client(_FakeNotificationClient()) as client:
        response = client.post(
            "/v1/push-registrations", json={**_VALID, "subject": "someone"}, headers=_AUTH
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_flood_is_rate_limited() -> None:
    with _client(_FakeNotificationClient(), registration_rate_limit=1) as client:
        first = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)
        second = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"


def test_an_unknown_lookup_passes_through_as_a_bad_request() -> None:
    notification = _FakeNotificationClient(
        status_code=400, body=b'{"code":"unknown_lookup","message":"No such lookup."}'
    )
    with _client(notification) as client:
        response = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "unknown_lookup"


def test_a_registration_declined_as_resolved_reports_not_registered() -> None:
    notification = _FakeNotificationClient(body=b'{"registered":false}')
    with _client(notification) as client:
        response = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)

    assert response.status_code == 202
    assert response.json() == {"registered": False}


def test_an_unavailable_notification_service_is_a_service_unavailable() -> None:
    notification = _FakeNotificationClient(error=UpstreamUnavailableError("down"))
    with _client(notification) as client:
        response = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"


def test_the_registration_budget_is_separate_from_the_lookup_budget() -> None:
    # A caller that has spent its lookup budget can still register a device; the
    # two are counted apart so a reading session does not block a notice.
    with _client(
        _FakeNotificationClient(), lookup_rate_limit=1, registration_rate_limit=5
    ) as client:
        lookups = [
            client.post(
                "/v1/lookups",
                json={
                    "selection": "coming",
                    "clientLookupId": f"c-{index}",
                    "platform": "android",
                    "locale": "en",
                    "consentModelProcessing": True,
                },
                headers=_AUTH,
            )
            for index in range(2)
        ]
        registered = client.post("/v1/push-registrations", json=_VALID, headers=_AUTH)

    assert lookups[0].status_code == 200
    assert lookups[1].status_code == 429
    assert registered.status_code == 202

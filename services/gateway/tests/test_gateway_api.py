"""Client API tests for the gateway (C-001, C-002 status and error mapping)."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier, Subject, TokenVerifier
from gateway.app.config import Settings
from gateway.app.lookup_client import UpstreamResponse
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_VALID = {
    "selection": "coming",
    "clientLookupId": "c-1",
    "platform": "android",
    "locale": "en",
    "consentModelProcessing": True,
}
_AUTH = {"Authorization": "Bearer dev:reader-1"}


class _Verifier:
    async def verify(self, authorization: str | None) -> Subject:
        return Subject(id="reader-1")


class _FakeLookupClient:
    def __init__(
        self,
        *,
        status_code: int = 200,
        body: bytes = b'{"lookupId":"lk_1"}',
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.last_payload: Mapping[str, Any] | None = None

    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        self.last_payload = payload
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"anonymized":0}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


def _client(
    lookup_client: _FakeLookupClient,
    *,
    verifier: TokenVerifier | None = None,
    rate_limit: int = 120,
) -> TestClient:
    app = create_app(
        settings=Settings(rate_limit_per_minute=rate_limit),
        verifier=verifier or _Verifier(),
        limiter=InMemoryFixedWindowRateLimiter(
            limit=rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
        lookup_client=lookup_client,
    )
    return TestClient(app)


def test_health() -> None:
    # /health is the path the platform probes; /healthz stays as the local
    # image-smoke alias (ci/checks/build.sh).
    with _client(_FakeLookupClient()) as client:
        canonical = client.get("/health")
        alias = client.get("/healthz")

    assert canonical.status_code == 200
    assert canonical.json() == {"status": "ok", "service": "gateway"}
    assert alias.status_code == 200


def test_a_missing_token_is_unauthorized() -> None:
    with _client(_FakeLookupClient(), verifier=DevTokenVerifier()) as client:
        response = client.post("/v1/lookups", json=_VALID)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_empty_selection_is_a_bad_request() -> None:
    with _client(_FakeLookupClient()) as client:
        response = client.post("/v1/lookups", json={**_VALID, "selection": "   "}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "empty_selection"


def test_an_invalid_platform_is_a_bad_request() -> None:
    with _client(_FakeLookupClient()) as client:
        response = client.post("/v1/lookups", json={**_VALID, "platform": "web"}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_rate_limited_caller_gets_429() -> None:
    with _client(_FakeLookupClient(), rate_limit=1) as client:
        first = client.post("/v1/lookups", json=_VALID, headers=_AUTH)
        second = client.post("/v1/lookups", json=_VALID, headers=_AUTH)

    assert first.status_code == 200
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"


def test_a_successful_lookup_passes_through_with_the_correlation_id() -> None:
    lookup_client = _FakeLookupClient()
    with _client(lookup_client) as client:
        response = client.post(
            "/v1/lookups",
            json=_VALID,
            headers={**_AUTH, "x-correlation-id": "corr-1"},
        )

    assert response.status_code == 200
    assert response.json() == {"lookupId": "lk_1"}
    assert response.headers["x-correlation-id"] == "corr-1"
    assert lookup_client.last_payload is not None
    assert lookup_client.last_payload["subject"] == "reader-1"
    assert lookup_client.last_payload["isAnonymous"] is False
    assert lookup_client.last_payload["selection"] == "coming"


def test_a_signed_out_reader_is_forwarded_as_anonymous() -> None:
    # The lookup path meters a signed-in reader and leaves a guest to the device,
    # so the gateway tells it which one the token is (C-001).
    lookup_client = _FakeLookupClient()
    with _client(lookup_client, verifier=DevTokenVerifier()) as client:
        response = client.post(
            "/v1/lookups",
            json=_VALID,
            headers={"Authorization": "Bearer dev-anon:device-9"},
        )

    assert response.status_code == 200
    assert lookup_client.last_payload is not None
    assert lookup_client.last_payload["subject"] == "device-9"
    assert lookup_client.last_payload["isAnonymous"] is True


def test_an_upstream_conflict_passes_through() -> None:
    with _client(_FakeLookupClient(status_code=409, body=b'{"code":"conflict"}')) as client:
        response = client.post("/v1/lookups", json=_VALID, headers=_AUTH)

    assert response.status_code == 409
    assert response.json() == {"code": "conflict"}


def test_an_unknown_lookup_passes_through_as_not_found() -> None:
    with _client(_FakeLookupClient(status_code=404, body=b'{"code":"lookup_not_found"}')) as client:
        response = client.get("/v1/lookups/lk_missing", headers=_AUTH)

    assert response.status_code == 404
    assert response.json() == {"code": "lookup_not_found"}

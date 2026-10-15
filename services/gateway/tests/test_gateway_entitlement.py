"""Gateway tests for the entitlement read, the account update, and the account
deletion (C-018, C-020, C-021).

The gateway authenticates the reader's token before it forwards the call to the
entitlement service and passes the service's status and body back unchanged, so a
401, a 400, or a 503 reaches the client as the service produced it.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier
from gateway.app.config import Settings
from gateway.app.entitlement_client import EntitlementClient
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.lookup_client import UpstreamResponse
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_READER = {"Authorization": "Bearer dev:reader-1"}


class _FakeEntitlementClient:
    """An entitlement client that records the call it was handed."""

    def __init__(
        self,
        *,
        status_code: int = 200,
        body: bytes = b"{}",
        error: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.error = error
        self.last_method: str | None = None
        self.last_path: str | None = None
        self.last_payload: Mapping[str, Any] | None = None
        self.last_authorization: str | None = None

    async def get_entitlement(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "GET"
        self.last_path = "/v1/entitlement"
        self.last_authorization = authorization
        return self._respond()

    async def update_account(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "PATCH"
        self.last_path = "/v1/account"
        self.last_payload = payload
        self.last_authorization = authorization
        return self._respond()

    async def delete_account(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "DELETE"
        self.last_path = "/v1/account"
        self.last_authorization = authorization
        return self._respond()

    async def aclose(self) -> None:
        return None

    def _respond(self) -> UpstreamResponse:
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )


def _client(entitlement: EntitlementClient) -> TestClient:
    return TestClient(
        create_app(
            settings=Settings(),
            verifier=DevTokenVerifier(),
            limiter=InMemoryFixedWindowRateLimiter(limit=120, window_seconds=60, clock=lambda: 0.0),
            entitlement_client=entitlement,
        )
    )


def test_the_entitlement_read_passes_through_with_the_reader_token() -> None:
    entitlement = _FakeEntitlementClient(
        body=b'{"plan":"free","lookupsUsed":3,"lookupsLimit":20,"periodStart":"a",'
        b'"periodEnd":"b","status":"active","trialEndsAt":null}'
    )

    with _client(entitlement) as client:
        response = client.get("/v1/entitlement", headers={**_READER, "x-correlation-id": "corr-1"})

    assert response.status_code == 200
    assert response.json()["lookupsUsed"] == 3
    assert response.headers["x-correlation-id"] == "corr-1"
    assert entitlement.last_method == "GET"
    assert entitlement.last_path == "/v1/entitlement"
    assert entitlement.last_authorization == _READER["Authorization"]


def test_the_account_update_passes_through_with_its_body() -> None:
    entitlement = _FakeEntitlementClient(body=b'{"consentModelProcessing":true,"locale":"en"}')

    with _client(entitlement) as client:
        response = client.patch(
            "/v1/account", headers=_READER, json={"consentModelProcessing": True, "locale": "en"}
        )

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": True, "locale": "en"}
    assert entitlement.last_method == "PATCH"
    assert entitlement.last_payload == {"consentModelProcessing": True, "locale": "en"}


def test_the_account_deletion_passes_through_with_the_reader_token() -> None:
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"deleted":true}')

    with _client(entitlement) as client:
        response = client.delete("/v1/account", headers={**_READER, "x-correlation-id": "corr-2"})

    assert response.status_code == 202
    assert response.json() == {"deleted": True}
    assert response.headers["x-correlation-id"] == "corr-2"
    assert entitlement.last_method == "DELETE"
    assert entitlement.last_path == "/v1/account"
    assert entitlement.last_authorization == _READER["Authorization"]


def test_a_missing_token_is_unauthorized_before_the_service_is_called() -> None:
    entitlement = _FakeEntitlementClient()

    with _client(entitlement) as client:
        read = client.get("/v1/entitlement")
        update = client.patch("/v1/account", json={"locale": "en"})
        delete = client.delete("/v1/account")

    assert read.status_code == 401
    assert update.status_code == 401
    assert delete.status_code == 401
    assert read.json()["code"] == "unauthorized"
    assert entitlement.last_path is None


def test_a_deleted_account_error_passes_through() -> None:
    entitlement = _FakeEntitlementClient(
        status_code=401, body=b'{"code":"no_account","message":"This account no longer exists."}'
    )

    with _client(entitlement) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_a_service_error_passes_through() -> None:
    entitlement = _FakeEntitlementClient(
        status_code=400, body=b'{"code":"unknown_locale","message":"That language is unknown."}'
    )

    with _client(entitlement) as client:
        response = client.patch("/v1/account", headers=_READER, json={"locale": "zz"})

    assert response.status_code == 400
    assert response.json()["code"] == "unknown_locale"


def test_an_unreachable_entitlement_service_is_a_service_unavailable() -> None:
    entitlement = _FakeEntitlementClient(error=UpstreamUnavailableError("down"))

    with _client(entitlement) as client:
        response = client.get("/v1/entitlement", headers=_READER)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"

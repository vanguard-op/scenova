"""The gateway's published surface: the interactive schema is off where it runs.

The schema is a development aid; a deployed gateway must not publish it, because
it advertises the operator routes beside the reader routes and hands an attacker
a map of the internal surface (nfr.md "Security"; architecture.md "Component:
API Gateway"). Local development keeps it. These tests pin both halves, and that
suppressing the schema leaves the contract routes alone.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import Subject
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

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"anonymized":0}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


def _client(*, docs_enabled: bool) -> TestClient:
    return TestClient(
        create_app(
            settings=Settings(docs_enabled=docs_enabled),
            verifier=_Verifier(),
            limiter=InMemoryFixedWindowRateLimiter(limit=120, window_seconds=60, clock=lambda: 0.0),
            lookup_client=_FakeLookupClient(),
        )
    )


def test_the_deployed_surface_publishes_no_schema() -> None:
    client = _client(docs_enabled=False)
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404


def test_development_keeps_the_schema() -> None:
    client = _client(docs_enabled=True)
    assert client.get("/docs").status_code == 200
    assert client.get("/redoc").status_code == 200
    schema = client.get("/openapi.json")
    assert schema.status_code == 200
    assert "/v1/lookups" in schema.json()["paths"]


def test_suppressing_the_schema_leaves_the_contract_routes_alone() -> None:
    client = _client(docs_enabled=False)
    assert client.get("/health").status_code == 200
    response = client.post("/v1/lookups", json=_VALID, headers=_AUTH)
    assert response.status_code == 200


def test_schema_publishing_is_derived_from_the_environment() -> None:
    # Unset resolves to the local default, so a developer keeps the schema.
    assert Settings.from_env({}).docs_enabled is True
    assert Settings.from_env({"ENVIRONMENT": "dev"}).docs_enabled is True
    # Every deployed environment withholds it.
    for environment in ("pre-revenue", "staging", "prod"):
        assert Settings.from_env({"ENVIRONMENT": environment}).docs_enabled is False


def test_docs_enabled_overrides_the_environment() -> None:
    assert Settings.from_env({"ENVIRONMENT": "prod", "DOCS_ENABLED": "true"}).docs_enabled is True
    assert Settings.from_env({"ENVIRONMENT": "dev", "DOCS_ENABLED": "false"}).docs_enabled is False

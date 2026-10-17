"""The notification service's identity at the edge of the lookup service.

The notification service reads the lookup a push registration is about. The
lookup service is internal only, so Cloud Run admits a call only from an
authenticated service identity (architecture.md "Component: API Gateway"; nfr.md
NFR-020). This proves its client mints an ID token for the lookup service — its
own base URL, the audience Cloud Run binds the token to — and presents it on the
header Cloud Run reads.
"""

from __future__ import annotations

import httpx2
import pytest

from notification.app import service_identity
from notification.app.lookups import HttpLookupDirectory
from notification.app.service_identity import SERVERLESS_AUTHORIZATION_HEADER


class _Captured:
    """The headers a client sent, with a canned response to hand back."""

    def __init__(self, status_code: int, body: dict[str, object]) -> None:
        self.identity = ""
        self.internal_audience = ""
        self._status_code = status_code
        self._body = body

    def handle(self, request: httpx2.Request) -> httpx2.Response:
        self.identity = request.headers.get(SERVERLESS_AUTHORIZATION_HEADER, "")
        self.internal_audience = request.headers.get("x-internal-audience", "")
        return httpx2.Response(self._status_code, json=self._body)


def _enable_identity(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Turn the identity on as a deployed instance does, recording the audience."""

    audiences: list[str] = []

    def fetch(audience: str) -> str:
        audiences.append(audience)
        return "id-token"

    monkeypatch.setenv("K_SERVICE", "notification")
    monkeypatch.setattr(service_identity, "_fetch_id_token", fetch)
    return audiences


@pytest.mark.asyncio
async def test_the_lookup_client_mints_for_the_lookup_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(200, {"status": "generating"})
    client = HttpLookupDirectory(
        base_url="https://lookup.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.status("lk_1", "reader-1")
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://lookup.example"]

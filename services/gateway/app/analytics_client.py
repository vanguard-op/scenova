"""Internal client for the analytics event intake (C-007).

The gateway routes the client's event batch to the analytics service, which owns
the taxonomy and the personal-data scan. The caller's Authorization header is
forwarded unchanged, so the intake resolves the pseudonymous `user_id` from the
same token subject the gateway authenticated; the gateway never re-writes or
records the identity.

`anonymize_subject` calls the intake's internal seam when a reader's account is
deleted, so their events are anonymized across the store rather than only in the
primary database (analytics.md "Analytics Data Governance"). It is a
service-to-service call and carries the internal audience, not the reader's
token.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError
from .lookup_client import UpstreamResponse
from .service_identity import ServiceIdentity


class AnalyticsClient(Protocol):
    """Port for the analytics event intake."""

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpAnalyticsClient:
    """Calls the analytics intake over HTTP with the caller's own token."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 10.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The gateway asserts its own service identity at the platform edge; the
        # analytics intake is internal only (architecture.md "Component: API
        # Gateway"). The audience is this client's own base URL: Cloud Run binds
        # the ID token to the service being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        headers = {"x-correlation-id": correlation_id, **self._identity.headers()}
        if authorization is not None:
            headers["authorization"] = authorization
        try:
            response = await self._client.post("/v1/events", headers=headers, json=dict(payload))
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The analytics service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        headers = {
            "x-correlation-id": correlation_id,
            "x-internal-audience": self._internal_audience,
            **self._identity.headers(),
        }
        try:
            response = await self._client.post(
                "/internal/events/anonymize", headers=headers, json={"subject": subject}
            )
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The analytics service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

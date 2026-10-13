"""Internal client for the analytics event intake (C-007).

The gateway routes the client's event batch to the analytics service, which owns
the taxonomy and the personal-data scan. The caller's Authorization header is
forwarded unchanged, so the intake resolves the pseudonymous `user_id` from the
same token subject the gateway authenticated; the gateway never re-writes or
records the identity.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError
from .lookup_client import UpstreamResponse


class AnalyticsClient(Protocol):
    """Port for the analytics event intake."""

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpAnalyticsClient:
    """Calls the analytics intake over HTTP with the caller's own token."""

    def __init__(self, *, base_url: str, timeout_seconds: float = 10.0) -> None:
        self._client = httpx2.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout_seconds)

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        headers = {"x-correlation-id": correlation_id}
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

    async def aclose(self) -> None:
        await self._client.aclose()

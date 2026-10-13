"""Internal client for the push-registration intake (C-008).

The gateway routes the client's token registration to the notification service,
which owns the registration store and confirms the lookup before storing the
token. The caller's Authorization header is forwarded unchanged, so the intake
resolves the token subject the same way the gateway authenticated it; the gateway
never rewrites or records the identity and never sees the push token beyond
routing it.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError
from .lookup_client import UpstreamResponse


class PushRegistrationClient(Protocol):
    """Port for the notification service's registration intake."""

    async def register(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpPushRegistrationClient:
    """Calls the notification service over HTTP with the caller's own token."""

    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: float = 10.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def register(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        headers = {"x-correlation-id": correlation_id}
        if authorization is not None:
            headers["authorization"] = authorization
        try:
            response = await self._client.post(
                "/v1/push-registrations", headers=headers, json=dict(payload)
            )
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The notification service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

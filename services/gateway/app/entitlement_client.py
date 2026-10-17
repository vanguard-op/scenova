"""Internal client for the account and entitlement service (C-018 to C-022).

The gateway routes a reader's entitlement read, their account settings read,
their account update, and their account deletion to the entitlement service,
which owns the account and the allowance. The caller's Authorization header is
forwarded unchanged, so the service resolves the same token subject the gateway
authenticated and scopes the answer to that reader; the gateway never rewrites or
records the identity.

The gateway also carries the store billing sync (C-019). The payment processor is
not a reader, so the call is not a reader token's: the gateway forwards the
webhook's own Authorization header unchanged and the entitlement service decides
it — the processor's signed webhook or an internal service identity — and the
response, including a refusal, reaches the processor as the service produced it.
The webhook secret stays on the entitlement service alone, so the public surface
never holds the value it would need to forge a purchase.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError
from .lookup_client import UpstreamResponse


class EntitlementClient(Protocol):
    """Port for the entitlement service's reader-facing routes."""

    async def get_entitlement(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def get_account(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def update_account(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def delete_account(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def sync_entitlement(
        self, body: bytes, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpEntitlementClient:
    """Calls the entitlement service over HTTP with the caller's own token."""

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

    async def get_entitlement(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._request("GET", "/v1/entitlement", None, authorization, correlation_id)

    async def get_account(self, authorization: str | None, correlation_id: str) -> UpstreamResponse:
        return await self._request("GET", "/v1/account", None, authorization, correlation_id)

    async def update_account(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._request(
            "PATCH", "/v1/account", dict(payload), authorization, correlation_id
        )

    async def delete_account(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._request("DELETE", "/v1/account", None, authorization, correlation_id)

    async def sync_entitlement(
        self, body: bytes, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._request(
            "POST", "/internal/entitlements/sync", body, authorization, correlation_id
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | bytes | None,
        authorization: str | None,
        correlation_id: str,
    ) -> UpstreamResponse:
        headers = {"x-correlation-id": correlation_id}
        if authorization is not None:
            headers["authorization"] = authorization
        try:
            if isinstance(payload, bytes):
                headers["content-type"] = "application/json"
                response = await self._client.request(
                    method, path, headers=headers, content=payload
                )
            else:
                response = await self._client.request(method, path, headers=headers, json=payload)
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The entitlement service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

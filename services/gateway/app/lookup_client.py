"""Internal client for the lookup service."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError


@dataclass(frozen=True)
class UpstreamResponse:
    """A response passed back to the client unchanged."""

    status_code: int
    body: bytes
    content_type: str


class LookupClient(Protocol):
    """Port for the lookup service."""

    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse: ...

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse: ...

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpLookupClient:
    """Calls the lookup service over HTTP with the internal audience header."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 10.0,
    ) -> None:
        self._internal_audience = internal_audience
        self._client = httpx2.AsyncClient(base_url=base_url.rstrip("/"), timeout=timeout_seconds)

    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        return await self._request("POST", "/internal/lookups", correlation_id, json=dict(payload))

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        return await self._request(
            "GET",
            f"/internal/lookups/{lookup_id}",
            correlation_id,
            params={"subject": subject},
        )

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        return await self._request(
            "POST",
            "/internal/lookups/anonymize",
            correlation_id,
            json={"subject": subject},
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _request(
        self,
        method: str,
        path: str,
        correlation_id: str,
        *,
        json: Mapping[str, Any] | None = None,
        params: Mapping[str, str] | None = None,
    ) -> UpstreamResponse:
        headers = {
            "x-correlation-id": correlation_id,
            "x-internal-audience": self._internal_audience,
        }
        try:
            response = await self._client.request(
                method, path, headers=headers, json=json, params=params
            )
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The lookup service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

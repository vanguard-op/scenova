"""Internal client for the feedback intake (C-012, C-013).

The gateway routes a reader's rating and report to the feedback service, which
owns the feedback store, the review queue, and the hold on a reported entry. The
caller's Authorization header is forwarded unchanged, so the intake resolves the
token subject the same way the gateway authenticated it and scopes the work to
that reader; the gateway never rewrites or records the identity.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any, Protocol

import httpx2

from .errors import UpstreamUnavailableError
from .lookup_client import UpstreamResponse


class FeedbackClient(Protocol):
    """Port for the feedback service's rating and report intake."""

    async def record_feedback(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def record_report(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse: ...

    async def review(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, str] | None,
        body: bytes | None,
        authorization: str | None,
        correlation_id: str,
    ) -> UpstreamResponse: ...

    async def aclose(self) -> None: ...


class HttpFeedbackClient:
    """Calls the feedback service over HTTP with the caller's own token."""

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

    async def record_feedback(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._post("/v1/feedback", payload, authorization, correlation_id)

    async def record_report(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._post("/v1/reports", payload, authorization, correlation_id)

    async def review(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, str] | None,
        body: bytes | None,
        authorization: str | None,
        correlation_id: str,
    ) -> UpstreamResponse:
        """Forward a curator review call to the feedback service.

        The operator's own token is forwarded unchanged, so the review service
        resolves the same session the gateway authenticated; the gateway never
        rewrites or records the identity.
        """

        headers = {"x-correlation-id": correlation_id}
        if authorization is not None:
            headers["authorization"] = authorization
        if body is not None:
            headers["content-type"] = "application/json"
        try:
            response = await self._client.request(
                method,
                path,
                headers=headers,
                params=dict(params) if params else None,
                content=body,
            )
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The review service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    async def _post(
        self,
        path: str,
        payload: Mapping[str, Any],
        authorization: str | None,
        correlation_id: str,
    ) -> UpstreamResponse:
        headers = {"x-correlation-id": correlation_id}
        if authorization is not None:
            headers["authorization"] = authorization
        try:
            response = await self._client.post(path, headers=headers, json=dict(payload))
        except httpx2.HTTPError as exc:
            raise UpstreamUnavailableError("The feedback service is unavailable.") from exc
        return UpstreamResponse(
            status_code=response.status_code,
            body=response.content,
            content_type=response.headers.get("content-type", "application/json"),
        )

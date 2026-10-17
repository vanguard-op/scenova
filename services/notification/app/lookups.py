"""Port to the lookup service for the lookup a registration is about (C-008).

A registration is only meaningful for a lookup the reader owns and that can
still put a clip in front of them, so the intake asks the lookup service for that
lookup before it stores a token: an unknown or foreign lookup is refused, and a
lookup that resolved without a clip needs no notice. The lookup service owns
lookups, so this reads its internal lookup route scoped by the caller's subject
(the C-002 ownership rule, applied on the server side).

An unreachable lookup service is not an unknown lookup: `status` raises
`LookupUnavailableError` so the intake can decline to claim a notice it cannot
confirm rather than refuse a lookup it cannot see.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Protocol

import httpx2

from .service_identity import ServiceIdentity


class LookupUnavailableError(Exception):
    """The lookup service could not answer; a registration cannot be confirmed."""


class LookupStatus(StrEnum):
    """How the reader's lookup resolved (C-001 / C-002 `status`)."""

    SERVED = "served"
    GENERATING = "generating"
    FALLBACK = "fallback"
    DENIED = "denied"
    EMPTY = "empty"


class LookupDirectory(Protocol):
    """Reads the state of a lookup the caller owns."""

    async def status(self, lookup_id: str, subject: str) -> LookupStatus | None:
        """The lookup's status, or None when the reader has no such lookup."""
        ...

    async def aclose(self) -> None: ...


class HttpLookupDirectory:
    """Reads the lookup service over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 3.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The lookup service is internal only, so Cloud Run checks the caller's
        # identity at the platform edge (nfr.md NFR-020). The audience is this
        # client's own base URL: Cloud Run binds the ID token to the service
        # being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def status(self, lookup_id: str, subject: str) -> LookupStatus | None:
        try:
            response = await self._client.get(
                f"/internal/lookups/{lookup_id}",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                params={"subject": subject},
            )
        except httpx2.HTTPError as exc:
            raise LookupUnavailableError("The lookup service is unreachable.") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise LookupUnavailableError("The lookup service could not answer.")
        try:
            return LookupStatus(response.json()["status"])
        except (KeyError, TypeError, ValueError) as exc:
            raise LookupUnavailableError(
                "The lookup service returned an unreadable lookup."
            ) from exc

    async def aclose(self) -> None:
        await self._client.aclose()

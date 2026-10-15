"""Client for the lookup path's check-and-spend (FEAT-013).

A signed-in reader's lookup spends one unit of their monthly allowance before
the lookup serves or generates, so a hit on the shared library and a fresh
generation cost the reader the same (monetization.md "Revenue Model"). The
meter is an internal seam rather than a numbered contract: the entitlement
service owns it and the lookup service is its only caller.

A reader who has not signed in is metered on the device and holds no account,
so the lookup never spends against the service for them. When the meter cannot
be reached the lookup proceeds on the grace path instead of blocking the
reader, and the client reconciles the allowance later (architecture "Account &
Entitlement Service", NFR-011).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import httpx2


class EntitlementUnavailableError(Exception):
    """The meter could not answer; the lookup proceeds rather than blocking."""


@dataclass(frozen=True)
class SpendOutcome:
    """The meter's answer: whether the lookup may proceed, and the allowance after it."""

    allowed: bool
    lookups_used: int
    lookups_limit: int
    period_end: str


class EntitlementPort(Protocol):
    """Port for the lookup path's check-and-spend."""

    async def spend(self, subject: str, client_lookup_id: str) -> SpendOutcome:
        """Spend one unit for a signed-in reader, or report the allowance is spent."""
        ...

    async def aclose(self) -> None: ...


class HttpEntitlement:
    """Calls the entitlement service's spend seam with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 3.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def spend(self, subject: str, client_lookup_id: str) -> SpendOutcome:
        try:
            response = await self._client.post(
                "/internal/entitlements/spend",
                headers={"x-internal-audience": self._internal_audience},
                json={"subject": subject, "clientLookupId": client_lookup_id},
            )
        except httpx2.HTTPError as exc:
            raise EntitlementUnavailableError("The entitlement meter is unreachable.") from exc

        if response.status_code != 200:
            # Any non-200 is read as "the meter could not answer": the reader is
            # never blocked by a metering fault (NFR-011).
            raise EntitlementUnavailableError("The entitlement meter could not answer.")
        return _outcome(response)

    async def aclose(self) -> None:
        await self._client.aclose()


def _outcome(response: httpx2.Response) -> SpendOutcome:
    try:
        body = response.json()
        return SpendOutcome(
            allowed=bool(body["allowed"]),
            lookups_used=int(body["lookupsUsed"]),
            lookups_limit=int(body["lookupsLimit"]),
            period_end=str(body["periodEnd"]),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise EntitlementUnavailableError("The meter returned an unreadable answer.") from exc

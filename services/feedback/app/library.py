"""Port to the shared library for holding a reported entry (C-011).

A report holds the entry it is about from new readers until a curator reviews it,
so the intake moves the entry's status to `held` through the library's internal
update route. Holding is the only library write the feedback path makes: a rating
never changes the shared library (FEAT-010), and a report on a phrase clip has no
shared entry to hold at all (FEAT-011).

An unreachable library raises `LibraryUnavailableError`, which the intake reports
as the store being unavailable so the client retries; an entry that no longer
exists is not an outage — a replacement may have superseded it — so it is logged
and left alone.
"""

from __future__ import annotations

import logging
from typing import Protocol

import httpx2

logger = logging.getLogger(__name__)


class LibraryUnavailableError(Exception):
    """The shared library could not be reached to hold an entry."""


class LibraryPort(Protocol):
    """Holds a library entry from new readers after a report."""

    async def hold(self, entry_id: str) -> None:
        """Move an entry to `held`; a missing entry is a no-op."""
        ...

    async def aclose(self) -> None: ...


class HttpLibrary:
    """Updates the shared library over HTTP with the internal audience."""

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

    async def hold(self, entry_id: str) -> None:
        try:
            response = await self._client.patch(
                f"/internal/library/entries/{entry_id}",
                headers={"x-internal-audience": self._internal_audience},
                json={"status": "held"},
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 200:
            return
        if response.status_code == 404:
            # The entry was replaced or removed between the lookup read and the
            # hold; there is nothing left to hold.
            logger.warning("library entry %s no longer exists; nothing was held", entry_id)
            return
        raise LibraryUnavailableError("The shared library could not hold the entry.")

    async def aclose(self) -> None:
        await self._client.aclose()

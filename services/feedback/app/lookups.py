"""Port to the lookup service for the lookup a rating or report is about.

A rating or a report is only meaningful for a lookup the reader owns and that
actually served a clip, so the intake reads the lookup before it records
anything: an unknown or foreign lookup is refused, and a lookup that never put a
clip in front of the reader has nothing to rate. The lookup service owns lookups,
so this reads its internal lookup route scoped by the caller's subject (the C-002
ownership rule, applied on the server side).

The clip the reader saw is the entry a word lookup served; the served entries are
taken from the lookup's senses, so a rating is recorded against the same entry the
clip came from. A phrase lookup carries no sense and no shared entry — its clip is
private to the device — so it reports no served entries.

An unreachable lookup service is not an unknown lookup: `read` raises
`LookupUnavailableError` so the intake can report the store as unavailable rather
than refuse a lookup it cannot see.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import httpx2

from .models import LookupKind, LookupStatus


class LookupUnavailableError(Exception):
    """The lookup service could not answer; the lookup cannot be confirmed."""


@dataclass(frozen=True)
class LookupRecord:
    """The lookup a rating or report is about, with the entries it served."""

    lookup_id: str
    kind: LookupKind
    status: LookupStatus
    # The library entries the lookup served a clip from; empty for a phrase
    # lookup and for a word lookup that served no clip.
    served_entry_ids: tuple[str, ...]


class LookupDirectory(Protocol):
    """Reads the state of a lookup the caller owns."""

    async def read(self, lookup_id: str, subject: str) -> LookupRecord | None:
        """The lookup, or None when the reader has no such lookup."""
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
    ) -> None:
        self._internal_audience = internal_audience
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def read(self, lookup_id: str, subject: str) -> LookupRecord | None:
        try:
            response = await self._client.get(
                f"/internal/lookups/{lookup_id}",
                headers={"x-internal-audience": self._internal_audience},
                params={"subject": subject},
            )
        except httpx2.HTTPError as exc:
            raise LookupUnavailableError("The lookup service is unreachable.") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise LookupUnavailableError("The lookup service could not answer.")
        return _record(response)

    async def aclose(self) -> None:
        await self._client.aclose()


def _record(response: httpx2.Response) -> LookupRecord:
    try:
        body: dict[str, Any] = response.json()
        senses = body.get("senses") or []
        served = tuple(
            str(sense["entryId"])
            for sense in senses
            if sense.get("clip") is not None and sense.get("entryId")
        )
        return LookupRecord(
            lookup_id=str(body["lookupId"]),
            kind=LookupKind(body["kind"]),
            status=LookupStatus(body["status"]),
            served_entry_ids=served,
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise LookupUnavailableError("The lookup service returned an unreadable lookup.") from exc

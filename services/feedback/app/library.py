"""Port to the shared library for holding and reviewing a reported entry (C-011).

A report holds the entry it is about from new readers until a curator reviews it,
so the intake moves the entry's status to `held` through the library's internal
update route. Holding is the only library write the feedback path makes: a rating
never changes the shared library (FEAT-010), and a report on a phrase clip has no
shared entry to hold at all (FEAT-011).

The curator review surface (FEAT-015) reads an entry by id — the word, sense,
generation phrase, clip, and status a curator decides on — and moves its status
as the decision requires. An unreachable library raises `LibraryUnavailableError`;
an entry that no longer exists is reported as missing so the review surface can
answer the contract's 404.

An unreachable library raises `LibraryUnavailableError`, which the intake reports
as the store being unavailable so the client retries; an entry that no longer
exists is not an outage — a replacement may have superseded it — so the intake
logs it and leaves it alone.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Protocol

import httpx2

logger = logging.getLogger(__name__)


class LibraryUnavailableError(Exception):
    """The shared library could not be reached."""


class EntryMissingError(Exception):
    """The library holds no entry for the id the review surface addressed."""


@dataclass(frozen=True)
class LibraryEntryView:
    """A library entry as the curator review surface reads it (C-015)."""

    entry_id: str
    lemma: str
    sense_label: str
    part_of_speech: str
    gloss_phrase: str
    status: str
    clip_url: str
    clip_duration_seconds: float
    clip_resolution: str
    clip_has_audio: bool


class LibraryPort(Protocol):
    """Holds an entry after a report and serves the curator review surface."""

    async def hold(self, entry_id: str) -> None:
        """Move an entry to `held`; a missing entry is a no-op."""
        ...

    async def get_entry(self, entry_id: str) -> LibraryEntryView | None:
        """Read an entry by id, or None when the library holds none."""
        ...

    async def set_status(self, entry_id: str, status: str) -> None:
        """Move an entry's status, or raise when the id is unknown."""
        ...

    async def aclose(self) -> None: ...


class HttpLibrary:
    """Reads and updates the shared library over HTTP with the internal audience."""

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

    async def get_entry(self, entry_id: str) -> LibraryEntryView | None:
        try:
            response = await self._client.get(
                f"/internal/library/entries/{entry_id}",
                headers={"x-internal-audience": self._internal_audience},
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise LibraryUnavailableError("The shared library could not serve the entry.")
        return _entry_view(response)

    async def set_status(self, entry_id: str, status: str) -> None:
        try:
            response = await self._client.patch(
                f"/internal/library/entries/{entry_id}",
                headers={"x-internal-audience": self._internal_audience},
                json={"status": status},
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 200:
            return
        if response.status_code == 404:
            raise EntryMissingError("The shared library holds no such entry.")
        raise LibraryUnavailableError("The shared library could not move the entry.")

    async def aclose(self) -> None:
        await self._client.aclose()


def _entry_view(response: httpx2.Response) -> LibraryEntryView:
    try:
        body: dict[str, Any] = response.json()
        entry = body["entry"]
        clip = entry["clip"]
        return LibraryEntryView(
            entry_id=str(entry["entryId"]),
            lemma=str(entry["lemma"]),
            sense_label=str(entry["senseLabel"]),
            part_of_speech=str(entry["partOfSpeech"]),
            gloss_phrase=str(entry["glossPhrase"]),
            status=str(entry["status"]),
            clip_url=str(clip["url"]),
            clip_duration_seconds=float(clip["durationSeconds"]),
            clip_resolution=str(clip["resolution"]),
            clip_has_audio=bool(clip["hasAudio"]),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise LibraryUnavailableError("The shared library returned an unreadable entry.") from exc

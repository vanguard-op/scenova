"""Port to the shared library for reviewing a reported entry (C-011, C-017).

A report no longer holds the entry it is about: the entry keeps serving to other
readers while it is under review, and a curator decides which clip serves it
afterwards (FEAT-011, FEAT-015). So the feedback path never moves an entry's
status on a report; the review surface moves it only when a curator retires the
entry or edits its phrase.

The review surface reads an entry by id — the word, sense, generation phrase,
clip, and status a curator decides on — and reads the candidate clip regenerated
for the reporting reader, held beside the entry until the curator chooses. A
`choose candidate` promotes that candidate to the clip the entry serves.

An unreachable library raises `LibraryUnavailableError`; an entry that no longer
exists is reported as missing so the review surface can answer the contract's
404.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import httpx2

from .service_identity import ServiceIdentity


class LibraryUnavailableError(Exception):
    """The shared library could not be reached."""


class EntryMissingError(Exception):
    """The library holds no entry for the id the review surface addressed."""


@dataclass(frozen=True)
class LibraryClipView:
    """A clip as the review surface reads it (C-015 `clip` and `candidate`)."""

    url: str
    duration_seconds: float
    resolution: str
    has_audio: bool


@dataclass(frozen=True)
class LibraryEntryView:
    """A library entry as the curator review surface reads it (C-015)."""

    entry_id: str
    lemma: str
    sense_label: str
    part_of_speech: str
    gloss_phrase: str
    status: str
    clip: LibraryClipView


class LibraryPort(Protocol):
    """Reads entries and candidates, and moves an entry's status."""

    async def get_entry(self, entry_id: str) -> LibraryEntryView | None:
        """Read an entry by id, or None when the library holds none."""
        ...

    async def get_candidate(self, entry_id: str) -> LibraryClipView | None:
        """Read the candidate clip held for an entry, or None when there is none."""
        ...

    async def set_status(self, entry_id: str, status: str) -> None:
        """Move an entry's status, or raise when the id is unknown."""
        ...

    async def promote_candidate(self, entry_id: str) -> None:
        """Make the entry's candidate the clip it serves, or raise when there is none."""
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
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The shared library is internal only, so Cloud Run checks the caller's
        # identity at the platform edge (nfr.md NFR-020). The audience is this
        # client's own base URL: Cloud Run binds the ID token to the service
        # being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def get_entry(self, entry_id: str) -> LibraryEntryView | None:
        try:
            response = await self._client.get(
                f"/internal/library/entries/{entry_id}",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise LibraryUnavailableError("The shared library could not serve the entry.")
        return _entry_view(response)

    async def get_candidate(self, entry_id: str) -> LibraryClipView | None:
        try:
            response = await self._client.get(
                f"/internal/library/entries/{entry_id}/candidate",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 404:
            return None
        if response.status_code != 200:
            raise LibraryUnavailableError("The shared library could not serve the candidate.")
        return _candidate_view(response)

    async def set_status(self, entry_id: str, status: str) -> None:
        try:
            response = await self._client.patch(
                f"/internal/library/entries/{entry_id}",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                json={"status": status},
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 200:
            return
        if response.status_code == 404:
            raise EntryMissingError("The shared library holds no such entry.")
        raise LibraryUnavailableError("The shared library could not move the entry.")

    async def promote_candidate(self, entry_id: str) -> None:
        try:
            response = await self._client.post(
                f"/internal/library/entries/{entry_id}/candidate/promote",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code == 200:
            return
        if response.status_code == 404:
            raise EntryMissingError("The shared library holds no candidate for this entry.")
        raise LibraryUnavailableError("The shared library could not promote the candidate.")

    async def aclose(self) -> None:
        await self._client.aclose()


def _entry_view(response: httpx2.Response) -> LibraryEntryView:
    try:
        body: dict[str, Any] = response.json()
        entry = body["entry"]
        return LibraryEntryView(
            entry_id=str(entry["entryId"]),
            lemma=str(entry["lemma"]),
            sense_label=str(entry["senseLabel"]),
            part_of_speech=str(entry["partOfSpeech"]),
            gloss_phrase=str(entry["glossPhrase"]),
            status=str(entry["status"]),
            clip=_clip(entry["clip"]),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise LibraryUnavailableError("The shared library returned an unreadable entry.") from exc


def _candidate_view(response: httpx2.Response) -> LibraryClipView | None:
    try:
        body: dict[str, Any] = response.json()
        clip = body.get("clip")
        return None if clip is None else _clip(clip)
    except (KeyError, TypeError, ValueError) as exc:
        raise LibraryUnavailableError(
            "The shared library returned an unreadable candidate."
        ) from exc


def _clip(clip: dict[str, Any]) -> LibraryClipView:
    return LibraryClipView(
        url=str(clip["url"]),
        duration_seconds=float(clip["durationSeconds"]),
        resolution=str(clip["resolution"]),
        has_audio=bool(clip["hasAudio"]),
    )

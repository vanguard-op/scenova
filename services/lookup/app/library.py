"""Port to the shared word-clip library (FEAT-006).

The lookup service asks the library for the entry of a sense and serves its clip
when the entry is active. A miss is handed to the generation path. The store
returns an entry whatever its status, so a retired one is a miss too: the
entry's id seeds the regeneration, which lets a replacement be produced even
though the pipeline already recorded a generation for the sense key.

`find` raises `LibraryUnavailableError` when the library cannot be reached; the
lookup treats that as a miss and falls back to generation (FEAT-006 edge), so a
library outage never leaves the reader without the word and phrase.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Literal, Protocol

import httpx2

from .models import PartOfSpeech
from .service_identity import ServiceIdentity

LibraryKey = tuple[str, str, PartOfSpeech]


class LibraryUnavailableError(Exception):
    """The shared library could not answer; the lookup falls back to generation."""


class LibraryEntryStatus(StrEnum):
    """Whether an entry is served or retired (schema).

    An entry under review keeps serving; only a retired entry is withheld, and
    the lookup treats it as a miss and regenerates (FEAT-006).
    """

    ACTIVE = "active"
    RETIRED = "retired"


@dataclass(frozen=True)
class LibraryClip:
    """A stored clip served for a library entry."""

    url: str
    duration_seconds: float
    has_audio: bool
    resolution: Literal["360p"] = "360p"


@dataclass(frozen=True)
class LibraryEntry:
    """A shared library entry for one sense of a word."""

    id: str
    gloss_phrase: str
    clip: LibraryClip
    # The entry's review state; only an active entry is served (FEAT-006).
    status: LibraryEntryStatus = LibraryEntryStatus.ACTIVE


class LibraryPort(Protocol):
    """Port for the shared word-clip library."""

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        """Return the entry for a sense, or None when the library has no entry."""
        ...

    async def aclose(self) -> None: ...


class InMemoryLibrary:
    """An in-memory library, keyed by lemma, sense label, and part of speech."""

    def __init__(self, entries: Mapping[LibraryKey, LibraryEntry] | None = None) -> None:
        self._entries: dict[LibraryKey, LibraryEntry] = dict(entries or {})

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        return self._entries.get((lemma.casefold(), sense_label, part_of_speech))

    async def aclose(self) -> None:
        return None

    def add(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
        entry: LibraryEntry,
    ) -> None:
        self._entries[(lemma.casefold(), sense_label, part_of_speech)] = entry


class HttpLibrary:
    """Reads the shared library over HTTP with the internal audience."""

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

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        try:
            response = await self._client.get(
                "/internal/library/entries",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                params={
                    "lemma": lemma,
                    "senseLabel": sense_label,
                    "partOfSpeech": part_of_speech.value,
                },
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code != 200:
            raise LibraryUnavailableError("The shared library could not answer.")
        return _entry(response)

    async def aclose(self) -> None:
        await self._client.aclose()


def _entry(response: httpx2.Response) -> LibraryEntry | None:
    try:
        raw = response.json()["entry"]
        if raw is None:
            return None
        clip = raw["clip"]
        return LibraryEntry(
            id=raw["entryId"],
            gloss_phrase=raw["glossPhrase"],
            status=LibraryEntryStatus(raw["status"]),
            clip=LibraryClip(
                url=clip["url"],
                duration_seconds=float(clip["durationSeconds"]),
                has_audio=bool(clip["hasAudio"]),
            ),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise LibraryUnavailableError("The shared library returned an unreadable entry.") from exc

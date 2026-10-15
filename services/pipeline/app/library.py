"""Port to the shared word-clip library (FEAT-006).

A finished word clip is written here, keyed by lemma, sense, and part of speech,
so a later lookup serves it without generating again. A clip regenerated for a
reporting reader is written beside the entry as its candidate instead, held
until a curator chooses which clip serves (FEAT-011). Phrase clips are never
written here (FEAT-007).

A write that the library cannot accept raises `LibraryUnavailableError`; the
generation service keeps the job's success and still delivers the clip to the
reader, retrying the write (FEAT-006 edge). The store is in memory for the
reading phase and Cloud SQL replaces it behind the same port.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

import httpx2

from .jobs import ClipAsset, LibraryEntry
from .models import PartOfSpeech

logger = logging.getLogger(__name__)

LibraryKey = tuple[str, str, PartOfSpeech]


class LibraryUnavailableError(Exception):
    """The shared library could not accept a write; the clip still reaches the reader."""


@dataclass(frozen=True)
class StoredClip:
    """A library entry and the clip asset it references."""

    entry: LibraryEntry
    asset: ClipAsset


class LibraryWriter(Protocol):
    """Port for writing a word clip, or an entry's candidate, to the library."""

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None: ...

    async def store_candidate(self, entry_id: str, asset: ClipAsset) -> None: ...

    async def aclose(self) -> None: ...


class InMemoryLibraryWriter:
    """An in-memory library, keyed by lemma, sense label, and part of speech."""

    def __init__(self) -> None:
        self._clips: dict[LibraryKey, StoredClip] = {}
        self._candidates: dict[str, ClipAsset] = {}

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None:
        key: LibraryKey = (entry.lemma.casefold(), entry.sense_label, entry.part_of_speech)
        self._clips[key] = StoredClip(entry=entry, asset=asset)

    async def store_candidate(self, entry_id: str, asset: ClipAsset) -> None:
        self._candidates[entry_id] = asset

    async def aclose(self) -> None:
        return None

    def find(self, lemma: str, sense_label: str, part_of_speech: PartOfSpeech) -> StoredClip | None:
        return self._clips.get((lemma.casefold(), sense_label, part_of_speech))

    def candidate_for(self, entry_id: str) -> ClipAsset | None:
        return self._candidates.get(entry_id)

    def all(self) -> tuple[StoredClip, ...]:
        return tuple(self._clips.values())


class HttpLibraryWriter:
    """Writes a word clip to the shared library over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None:
        payload = {"entry": _entry_payload(entry), "asset": _asset_payload(asset)}
        try:
            response = await self._client.post(
                "/internal/library/entries",
                headers={"x-internal-audience": self._internal_audience},
                json=payload,
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code // 100 != 2:
            logger.warning("library write refused with status %s", response.status_code)
            raise LibraryUnavailableError("The shared library could not accept the clip.")

    async def store_candidate(self, entry_id: str, asset: ClipAsset) -> None:
        try:
            response = await self._client.post(
                f"/internal/library/entries/{entry_id}/candidate",
                headers={"x-internal-audience": self._internal_audience},
                json=_asset_payload(asset),
            )
        except httpx2.HTTPError as exc:
            raise LibraryUnavailableError("The shared library is unreachable.") from exc

        if response.status_code // 100 == 2:
            return
        if response.status_code == 404:
            # The entry was superseded between the report and the candidate; the
            # candidate has nowhere to sit and is dropped.
            logger.warning("library entry %s no longer exists; its candidate was dropped", entry_id)
            return
        raise LibraryUnavailableError("The shared library could not hold the candidate.")

    async def aclose(self) -> None:
        await self._client.aclose()


def _entry_payload(entry: LibraryEntry) -> dict[str, object]:
    return {
        "id": entry.id,
        "lemma": entry.lemma,
        "partOfSpeech": entry.part_of_speech.value,
        "senseLabel": entry.sense_label,
        "glossPhrase": entry.gloss_phrase,
        "clipAssetId": entry.clip_asset_id,
        "status": entry.status,
        "source": entry.source,
        "createdAt": entry.created_at,
        "updatedAt": entry.updated_at,
    }


def _asset_payload(asset: ClipAsset) -> dict[str, object]:
    return {
        "id": asset.id,
        "durationSeconds": asset.duration_seconds,
        "resolution": asset.resolution,
        "storageKey": asset.storage_key,
        "url": asset.url,
        "hasAudio": asset.has_audio,
        "synthIdWatermark": asset.synth_id_watermark,
        "createdAt": asset.created_at,
    }

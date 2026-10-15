"""Entry and clip persistence for the shared word-clip library (FEAT-006).

The library is keyed by the normalised word and its sense — lemma, sense label,
and part of speech — so a repeated lookup hits the same entry the library already
holds. Word entries only: a phrase clip never reaches this store (FEAT-007).

The store is in memory for the reading phase; Cloud SQL replaces it behind the
same port, holding the same schema entities, so no caller changes.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Protocol

from .models import ClipAssetBody, EntryStatus, LibraryEntryBody, PartOfSpeech

LibraryKey = tuple[str, str, PartOfSpeech]


@dataclass(frozen=True)
class StoredEntry:
    """A library entry together with the clip asset it references.

    `candidate` is the clip regenerated for a reporting reader, held beside the
    serving clip until a curator chooses which one serves (FEAT-011, FEAT-015);
    it is None until a report triggers one.
    """

    entry: LibraryEntryBody
    asset: ClipAssetBody
    candidate: ClipAssetBody | None = None


class LibraryStore(Protocol):
    """Port for library-entry persistence."""

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> StoredEntry | None:
        """The entry held for a sense, whatever its status, or None."""
        ...

    async def upsert(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> StoredEntry:
        """Write an entry, replacing whatever the key held before."""
        ...

    async def get(self, entry_id: str) -> StoredEntry | None:
        """The entry with this id, or None."""
        ...

    async def set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry | None:
        """Move an entry's status, or None when the id is unknown."""
        ...

    async def set_candidate(self, entry_id: str, asset: ClipAssetBody) -> StoredEntry | None:
        """Hold a candidate clip beside an entry's serving clip, or None if unknown."""
        ...

    async def promote_candidate(self, entry_id: str) -> StoredEntry | None:
        """Make the candidate clip the serving one, or None if there is none."""
        ...


class InMemoryLibraryStore:
    """An in-memory library, keyed by lemma, sense label, and part of speech."""

    def __init__(self) -> None:
        self._by_key: dict[LibraryKey, StoredEntry] = {}
        self._by_id: dict[str, StoredEntry] = {}

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> StoredEntry | None:
        return self._by_key.get(_key(lemma, sense_label, part_of_speech))

    async def upsert(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> StoredEntry:
        stored = StoredEntry(entry=entry, asset=asset)
        key = _key(entry.lemma, entry.senseLabel, entry.partOfSpeech)
        # A regenerated clip supersedes the entry the key held, so a retired
        # entry is replaced rather than duplicated, and the superseded entry's
        # candidate goes with it (FEAT-006).
        previous = self._by_key.get(key)
        if previous is not None:
            self._by_id.pop(previous.entry.id, None)
        self._by_key[key] = stored
        self._by_id[entry.id] = stored
        return stored

    async def get(self, entry_id: str) -> StoredEntry | None:
        return self._by_id.get(entry_id)

    async def set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry | None:
        stored = self._by_id.get(entry_id)
        if stored is None:
            return None
        updated = StoredEntry(
            entry=stored.entry.model_copy(
                update={"status": status, "updatedAt": _now()},
            ),
            asset=stored.asset,
            candidate=stored.candidate,
        )
        self._by_id[entry_id] = updated
        key = _key(updated.entry.lemma, updated.entry.senseLabel, updated.entry.partOfSpeech)
        self._by_key[key] = updated
        return updated

    async def set_candidate(self, entry_id: str, asset: ClipAssetBody) -> StoredEntry | None:
        stored = self._by_id.get(entry_id)
        if stored is None:
            return None
        updated = replace(stored, candidate=asset)
        self._by_id[entry_id] = updated
        key = _key(updated.entry.lemma, updated.entry.senseLabel, updated.entry.partOfSpeech)
        self._by_key[key] = updated
        return updated

    async def promote_candidate(self, entry_id: str) -> StoredEntry | None:
        stored = self._by_id.get(entry_id)
        if stored is None or stored.candidate is None:
            return None
        # The candidate becomes the serving clip; the clip it displaces is
        # dropped rather than kept as a candidate (FEAT-015 `choose candidate`).
        updated = StoredEntry(
            entry=stored.entry.model_copy(
                update={"clipAssetId": stored.candidate.id, "updatedAt": _now()},
            ),
            asset=stored.candidate,
            candidate=None,
        )
        self._by_id[entry_id] = updated
        key = _key(updated.entry.lemma, updated.entry.senseLabel, updated.entry.partOfSpeech)
        self._by_key[key] = updated
        return updated


def _key(lemma: str, sense_label: str, part_of_speech: PartOfSpeech) -> LibraryKey:
    return (lemma.casefold(), sense_label, part_of_speech)


def _now() -> str:
    return datetime.now(UTC).isoformat()

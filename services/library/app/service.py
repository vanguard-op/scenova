"""Library operations: store a word clip, find it by sense, move its status.

The lookup service reads an entry for a sense; the generation pipeline writes a
finished word clip; the content review service holds or retires an entry after a
report. All three share this seam, so the store's rules live in one place and the
HTTP routes stay thin.
"""

from __future__ import annotations

from .errors import EntryNotFoundError
from .models import ClipAssetBody, EntryStatus, LibraryEntryBody, PartOfSpeech
from .store import LibraryStore, StoredEntry


class LibraryService:
    """Reads and writes the shared word-clip library."""

    def __init__(self, *, store: LibraryStore) -> None:
        self._store = store

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> StoredEntry | None:
        """The entry held for a sense, whatever its status, or None."""

        return await self._store.find(lemma, sense_label, part_of_speech)

    async def store(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> StoredEntry:
        """Write a word clip, replacing whatever the sense key held before."""

        return await self._store.upsert(entry, asset)

    async def set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry:
        """Move an entry's status after review, or fail when the id is unknown."""

        updated = await self._store.set_status(entry_id, status)
        if updated is None:
            raise EntryNotFoundError("No library entry exists for this id.")
        return updated

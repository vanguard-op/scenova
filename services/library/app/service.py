"""Library operations: store a word clip, find it by sense, move its status.

The lookup service reads an entry for a sense; the generation pipeline writes a
finished word clip, and a report-triggered candidate clip beside it; the content
review service chooses which clip serves or retires an entry. All of them share
this seam, so the store's rules live in one place and the HTTP routes stay thin.
"""

from __future__ import annotations

from .config import Settings
from .db import create_engine
from .errors import EntryNotFoundError
from .models import ClipAssetBody, EntryStatus, LibraryEntryBody, PartOfSpeech
from .store import InMemoryLibraryStore, LibraryStore, PostgresLibraryStore, StoredEntry


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

    async def get(self, entry_id: str) -> StoredEntry:
        """The entry with this id, or fail when the id is unknown.

        The content review service addresses an entry by id, so an unknown id is
        a 404 rather than a miss.
        """

        stored = await self._store.get(entry_id)
        if stored is None:
            raise EntryNotFoundError("No library entry exists for this id.")
        return stored

    async def store(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> StoredEntry:
        """Write a word clip, replacing whatever the sense key held before."""

        return await self._store.upsert(entry, asset)

    async def set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry:
        """Move an entry's status after review, or fail when the id is unknown."""

        updated = await self._store.set_status(entry_id, status)
        if updated is None:
            raise EntryNotFoundError("No library entry exists for this id.")
        return updated

    async def set_candidate(self, entry_id: str, asset: ClipAssetBody) -> StoredEntry:
        """Hold the clip regenerated for a reporting reader, or fail if unknown."""

        updated = await self._store.set_candidate(entry_id, asset)
        if updated is None:
            raise EntryNotFoundError("No library entry exists for this id.")
        return updated

    async def promote_candidate(self, entry_id: str) -> StoredEntry:
        """Make an entry's candidate the clip it serves, or fail if there is none."""

        stored = await self._store.get(entry_id)
        if stored is None:
            raise EntryNotFoundError("No library entry exists for this id.")
        if stored.candidate is None:
            raise EntryNotFoundError("No candidate clip is held for this entry.")
        promoted = await self._store.promote_candidate(entry_id)
        if promoted is None:
            raise EntryNotFoundError("No candidate clip is held for this entry.")
        return promoted

    async def aclose(self) -> None:
        """Release the store's database connections."""

        await self._store.aclose()


def build_default_service(settings: Settings | None = None) -> LibraryService:
    """Build the library service against the primary database when one is set.

    An environment with no `DATABASE_URL` keeps the in-memory store, so a bare
    local run and the unit tests need no database; every deployed environment
    resolves the relational store.
    """

    resolved = settings or Settings.from_env()
    if resolved.database_url is None:
        return LibraryService(store=InMemoryLibraryStore())
    return LibraryService(store=PostgresLibraryStore(create_engine(resolved.database_url)))

"""Entry and clip persistence for the shared word-clip library (FEAT-006).

The library is keyed by the normalised word and its sense — lemma, sense label,
and part of speech — so a repeated lookup hits the same entry the library already
holds. Word entries only: a phrase clip never reaches this store (FEAT-007).

Two implementations sit behind one port: the in-memory store the unit tests and a
bare local run use, and the relational store that is the primary database
(architecture.md "Primary Database"). A caller cannot tell them apart.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Literal, Protocol, cast

from sqlalchemy import Select, func, or_, select
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .db import ClipAssetRow, LibraryEntryRow
from .errors import LibraryUnavailableError
from .models import ClipAssetBody, EntrySource, EntryStatus, LibraryEntryBody, PartOfSpeech

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

    async def aclose(self) -> None:
        """Release whatever the store holds open."""
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

    async def aclose(self) -> None:
        return None


class PostgresLibraryStore:
    """The shared library in the primary relational database.

    The tables are the platform's migration history (`infra/db/migrations`), so
    the store maps them and never creates them. Each call runs its query on a
    worker thread, so a slow database never blocks the event loop the reader's
    lookup runs on (NFR-002). Every failure to reach the database is reported as
    the library being unavailable, so the API answers 503 for the internal
    contracts (C-009 to C-011, C-017) and the lookup falls back to generation
    (FEAT-006 edge).
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> StoredEntry | None:
        return await asyncio.to_thread(self._find, lemma, sense_label, part_of_speech)

    async def get(self, entry_id: str) -> StoredEntry | None:
        return await asyncio.to_thread(self._get, entry_id)

    async def upsert(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> StoredEntry:
        await asyncio.to_thread(self._upsert, entry, asset)
        return StoredEntry(entry=entry, asset=asset)

    async def set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry | None:
        return await asyncio.to_thread(self._set_status, entry_id, status)

    async def set_candidate(self, entry_id: str, asset: ClipAssetBody) -> StoredEntry | None:
        return await asyncio.to_thread(self._set_candidate, entry_id, asset)

    async def promote_candidate(self, entry_id: str) -> StoredEntry | None:
        return await asyncio.to_thread(self._promote_candidate, entry_id)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    def _find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> StoredEntry | None:
        return self._read_one(
            select(LibraryEntryRow).where(
                LibraryEntryRow.lemma_key == lemma.casefold(),
                LibraryEntryRow.sense_label == sense_label,
                LibraryEntryRow.part_of_speech == part_of_speech.value,
            )
        )

    def _get(self, entry_id: str) -> StoredEntry | None:
        return self._read_one(select(LibraryEntryRow).where(LibraryEntryRow.id == entry_id))

    def _upsert(self, entry: LibraryEntryBody, asset: ClipAssetBody) -> None:
        try:
            with self._sessions() as session, session.begin():
                _write_asset(session, asset)
                previous = session.scalar(
                    select(LibraryEntryRow).where(
                        LibraryEntryRow.lemma_key == entry.lemma.casefold(),
                        LibraryEntryRow.sense_label == entry.senseLabel,
                        LibraryEntryRow.part_of_speech == entry.partOfSpeech.value,
                    )
                )
                if previous is not None:
                    superseded = {
                        previous.clip_asset_id,
                        previous.candidate_clip_asset_id,
                    } - {asset.id}
                    session.delete(previous)
                    session.flush()
                    for asset_id in superseded:
                        if asset_id is not None:
                            _delete_asset_if_unused(session, asset_id)
                session.add(
                    LibraryEntryRow(
                        id=entry.id,
                        lemma_key=entry.lemma.casefold(),
                        lemma=entry.lemma,
                        part_of_speech=entry.partOfSpeech.value,
                        sense_label=entry.senseLabel,
                        gloss_phrase=entry.glossPhrase,
                        clip_asset_id=asset.id,
                        candidate_clip_asset_id=None,
                        status=entry.status.value,
                        source=entry.source.value,
                        created_at=entry.createdAt,
                        updated_at=entry.updatedAt,
                    )
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _set_status(self, entry_id: str, status: EntryStatus) -> StoredEntry | None:
        try:
            with self._sessions() as session, session.begin():
                row = _load_entry(session, entry_id)
                if row is None:
                    return None
                row.status = status.value
                row.updated_at = _now()
                return _stored(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _set_candidate(self, entry_id: str, asset: ClipAssetBody) -> StoredEntry | None:
        try:
            with self._sessions() as session, session.begin():
                row = _load_entry(session, entry_id)
                if row is None:
                    return None
                candidate = _write_asset(session, asset)
                displaced = row.candidate_clip_asset_id
                # The candidate is held through the relationship, so the entry
                # read back carries it rather than the clip it displaces.
                row.candidate = candidate
                session.flush()
                if displaced is not None and displaced != asset.id:
                    _delete_asset_if_unused(session, displaced)
                return _stored(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _promote_candidate(self, entry_id: str) -> StoredEntry | None:
        try:
            with self._sessions() as session, session.begin():
                row = _load_entry(session, entry_id)
                if row is None or row.candidate is None:
                    return None
                # The candidate becomes the serving clip; the clip it displaces
                # is dropped rather than kept as a candidate (FEAT-015
                # `choose candidate`).
                promoted = row.candidate
                displaced = row.clip_asset_id
                row.asset = promoted
                row.candidate = None
                row.updated_at = _now()
                session.flush()
                if displaced != promoted.id:
                    _delete_asset_if_unused(session, displaced)
                return StoredEntry(
                    entry=_entry_body(row),
                    asset=_asset_body(promoted),
                    candidate=None,
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _read_one(self, statement: Select[tuple[LibraryEntryRow]]) -> StoredEntry | None:
        try:
            with self._sessions() as session:
                row = session.scalar(statement)
                return None if row is None else _stored(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def _load_entry(session: Session, entry_id: str) -> LibraryEntryRow | None:
    row: LibraryEntryRow | None = session.scalar(
        select(LibraryEntryRow).where(LibraryEntryRow.id == entry_id)
    )
    return row


def _write_asset(session: Session, asset: ClipAssetBody) -> ClipAssetRow:
    """Insert the clip, or bring the row already under its id up to date."""

    row = session.get(ClipAssetRow, asset.id)
    if row is None:
        row = ClipAssetRow(
            id=asset.id,
            duration_seconds=asset.durationSeconds,
            resolution=asset.resolution,
            storage_key=asset.storageKey,
            url=asset.url,
            has_audio=asset.hasAudio,
            synth_id_watermark=asset.synthIdWatermark,
            created_at=asset.createdAt,
        )
        session.add(row)
        return row
    row.duration_seconds = asset.durationSeconds
    row.resolution = asset.resolution
    row.storage_key = asset.storageKey
    row.url = asset.url
    row.has_audio = asset.hasAudio
    row.synth_id_watermark = asset.synthIdWatermark
    row.created_at = asset.createdAt
    return row


def _delete_asset_if_unused(session: Session, asset_id: str) -> None:
    """Drop a clip row no entry references any more.

    A superseded clip's file ages out of object storage on its own retention
    schedule; leaving its row behind would only be a row no entry can reach.
    """

    referenced: int = (
        session.scalar(
            select(func.count())
            .select_from(LibraryEntryRow)
            .where(
                or_(
                    LibraryEntryRow.clip_asset_id == asset_id,
                    LibraryEntryRow.candidate_clip_asset_id == asset_id,
                )
            )
        )
        or 0
    )
    if referenced:
        return
    row = session.get(ClipAssetRow, asset_id)
    if row is not None:
        session.delete(row)


def _stored(row: LibraryEntryRow) -> StoredEntry:
    return StoredEntry(
        entry=_entry_body(row),
        asset=_asset_body(row.asset),
        candidate=None if row.candidate is None else _asset_body(row.candidate),
    )


def _entry_body(row: LibraryEntryRow) -> LibraryEntryBody:
    return LibraryEntryBody(
        id=row.id,
        lemma=row.lemma,
        partOfSpeech=PartOfSpeech(row.part_of_speech),
        senseLabel=row.sense_label,
        glossPhrase=row.gloss_phrase,
        clipAssetId=row.clip_asset_id,
        status=EntryStatus(row.status),
        source=EntrySource(row.source),
        createdAt=row.created_at,
        updatedAt=row.updated_at,
    )


def _asset_body(row: ClipAssetRow) -> ClipAssetBody:
    return ClipAssetBody(
        id=row.id,
        durationSeconds=row.duration_seconds,
        resolution=cast('Literal["360p"]', row.resolution),
        storageKey=row.storage_key,
        url=row.url,
        hasAudio=row.has_audio,
        synthIdWatermark=row.synth_id_watermark,
        createdAt=row.created_at,
    )


def _unavailable() -> LibraryUnavailableError:
    return LibraryUnavailableError("The shared library is unavailable.")


def _key(lemma: str, sense_label: str, part_of_speech: PartOfSpeech) -> LibraryKey:
    return (lemma.casefold(), sense_label, part_of_speech)


def _now() -> str:
    return datetime.now(UTC).isoformat()

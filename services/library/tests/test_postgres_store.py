"""Relational store tests for the shared word-clip library (FEAT-006).

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: the entry and clip entities and
their reference, the sense key a repeat lookup hits, and the candidate a report
holds until a curator resolves it (schema.md "LibraryEntry", "ClipAsset";
C-009 to C-011, C-017).

The real tables are the platform's migration history (`infra/db/migrations`);
the tests build the same shape from the store's model metadata, so the queries
and the row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import pytest
from sqlalchemy import UniqueConstraint, create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import sessionmaker

from library.app.config import Settings
from library.app.db import Base, ClipAssetRow, LibraryEntryRow
from library.app.errors import LibraryUnavailableError
from library.app.models import (
    ClipAssetBody,
    EntrySource,
    EntryStatus,
    LibraryEntryBody,
    PartOfSpeech,
)
from library.app.service import build_default_service
from library.app.store import PostgresLibraryStore

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"


@asynccontextmanager
async def _store(tmp_path: Path) -> AsyncIterator[tuple[PostgresLibraryStore, Engine]]:
    engine = create_engine(f"sqlite:///{tmp_path / 'library.db'}")
    Base.metadata.create_all(engine)
    store = PostgresLibraryStore(engine)
    try:
        yield store, engine
    finally:
        await store.aclose()


def _entry(entry_id: str = "le_1", *, lemma: str = "come") -> LibraryEntryBody:
    return LibraryEntryBody(
        id=entry_id,
        lemma=lemma,
        partOfSpeech=PartOfSpeech.VERB,
        senseLabel="arrive",
        glossPhrase="to move toward a place",
        clipAssetId="clip_1",
        status=EntryStatus.ACTIVE,
        source=EntrySource.GENERATED,
        createdAt="2026-10-13T00:00:00+00:00",
        updatedAt="2026-10-13T00:00:00+00:00",
    )


def _asset(asset_id: str = "clip_1") -> ClipAssetBody:
    return ClipAssetBody(
        id=asset_id,
        durationSeconds=3.0,
        resolution="360p",
        storageKey=f"clips/{asset_id}.mp4",
        url=f"https://cdn.example/{asset_id}.mp4",
        hasAudio=False,
        synthIdWatermark=True,
        createdAt="2026-10-13T00:00:00+00:00",
    )


def test_the_schema_keys_entries_by_lemma_and_sense_and_references_the_clip() -> None:
    # schema.md "LibraryEntry" and its relationship: the key is lemma, sense
    # label, and part of speech, and the entry references the clip it serves.
    table = LibraryEntryRow.metadata.tables["library_entries"]
    unique_keys = {
        tuple(sorted(column.name for column in constraint.columns))
        for constraint in table.constraints
        if isinstance(constraint, UniqueConstraint)
    }
    assert ("lemma_key", "part_of_speech", "sense_label") in unique_keys
    assert {foreign_key.parent.name for foreign_key in table.foreign_keys} == {
        "clip_asset_id",
        "candidate_clip_asset_id",
    }


@pytest.mark.asyncio
async def test_a_stored_entry_is_found_by_its_sense_key(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(), _asset())

        stored = await store.find("come", "arrive", PartOfSpeech.VERB)

    assert stored is not None
    assert stored.entry.id == "le_1"
    assert stored.asset.id == "clip_1"
    assert stored.asset.url == "https://cdn.example/clip_1.mp4"


@pytest.mark.asyncio
async def test_the_key_is_case_insensitive(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(lemma="Come"), _asset())

        assert await store.find("come", "arrive", PartOfSpeech.VERB) is not None


@pytest.mark.asyncio
async def test_an_absent_key_is_a_miss(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        assert await store.find("come", "arrive", PartOfSpeech.VERB) is None


@pytest.mark.asyncio
async def test_the_entry_is_persisted_against_the_clip_asset_it_serves(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, engine):
        await store.upsert(_entry(), _asset())

        with sessionmaker(engine, expire_on_commit=False)() as session:
            asset = session.get(ClipAssetRow, "clip_1")

    assert asset is not None
    assert asset.storage_key == "clips/clip_1.mp4"
    assert asset.duration_seconds == 3.0
    assert asset.synth_id_watermark is True


@pytest.mark.asyncio
async def test_a_regenerated_clip_replaces_the_entry_for_the_key(tmp_path: Path) -> None:
    # A replacement supersedes what the key held; a retired entry is overwritten
    # rather than left beside its successor, and the clip it served goes with it
    # (FEAT-006).
    async with _store(tmp_path) as (store, engine):
        await store.upsert(_entry("le_old"), _asset("clip_old"))

        await store.upsert(_entry("le_new"), _asset("clip_new"))

        stored = await store.find("come", "arrive", PartOfSpeech.VERB)
        superseded = await store.get("le_old")
        with sessionmaker(engine, expire_on_commit=False)() as session:
            old_clip = session.get(ClipAssetRow, "clip_old")

    assert stored is not None and stored.entry.id == "le_new"
    assert superseded is None
    assert old_clip is None


@pytest.mark.asyncio
async def test_re_storing_the_same_entry_id_replaces_it_rather_than_conflicting(
    tmp_path: Path,
) -> None:
    # The pipeline retries a write it could not confirm, so the same entry id and
    # sense key must land once rather than failing on the primary key (C-009).
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry("le_1"), _asset("clip_1"))

        await store.upsert(
            _entry("le_1").model_copy(update={"glossPhrase": "to reach a place"}),
            _asset("clip_2"),
        )

        stored = await store.find("come", "arrive", PartOfSpeech.VERB)

    assert stored is not None
    assert stored.entry.id == "le_1"
    assert stored.entry.glossPhrase == "to reach a place"
    assert stored.asset.id == "clip_2"


@pytest.mark.asyncio
async def test_a_status_change_moves_the_entry_and_keeps_the_key(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(), _asset())

        updated = await store.set_status("le_1", EntryStatus.RETIRED)

        stored = await store.find("come", "arrive", PartOfSpeech.VERB)

    assert updated is not None
    assert updated.entry.status is EntryStatus.RETIRED
    assert stored is not None and stored.entry.status is EntryStatus.RETIRED


@pytest.mark.asyncio
async def test_an_unknown_entry_cannot_change_status(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        assert await store.set_status("le_missing", EntryStatus.RETIRED) is None


@pytest.mark.asyncio
async def test_a_candidate_is_held_beside_the_entry_and_promoted(tmp_path: Path) -> None:
    # The clip regenerated for a reporting reader is held beside the serving clip
    # until a curator chooses it; promoting it makes it the clip served (FEAT-011,
    # FEAT-015).
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(), _asset("clip_1"))

        held = await store.set_candidate("le_1", _asset("clip_cand"))
        promoted = await store.promote_candidate("le_1")
        found = await store.find("come", "arrive", PartOfSpeech.VERB)

    assert held is not None
    assert held.asset.id == "clip_1", "the serving clip is unchanged while a candidate is held"
    assert held.candidate is not None and held.candidate.id == "clip_cand"
    assert promoted is not None
    assert promoted.asset.id == "clip_cand"
    assert promoted.candidate is None
    assert found is not None and found.asset.id == "clip_cand"


@pytest.mark.asyncio
async def test_a_status_change_keeps_the_held_candidate(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(), _asset("clip_1"))
        await store.set_candidate("le_1", _asset("clip_cand"))

        updated = await store.set_status("le_1", EntryStatus.RETIRED)

    assert updated is not None and updated.candidate is not None
    assert updated.candidate.id == "clip_cand"


@pytest.mark.asyncio
async def test_an_unknown_entry_cannot_take_a_candidate(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        assert await store.set_candidate("le_missing", _asset()) is None


@pytest.mark.asyncio
async def test_promoting_without_a_candidate_is_none(tmp_path: Path) -> None:
    async with _store(tmp_path) as (store, _):
        await store.upsert(_entry(), _asset())

        assert await store.promote_candidate("le_1") is None


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_unavailable() -> None:
    store = PostgresLibraryStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(LibraryUnavailableError):
            await store.find("come", "arrive", PartOfSpeech.VERB)
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_the_default_service_stores_to_the_database_when_one_is_configured(
    tmp_path: Path,
) -> None:
    url = f"sqlite:///{tmp_path / 'service.db'}"
    Base.metadata.create_all(create_engine(url))
    service = build_default_service(Settings(database_url=url))
    try:
        await service.store(_entry(), _asset())
        found = await service.find("come", "arrive", PartOfSpeech.VERB)
    finally:
        await service.aclose()

    assert found is not None and found.entry.id == "le_1"


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None

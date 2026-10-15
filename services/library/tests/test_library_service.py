"""Store tests for the shared word-clip library (FEAT-006)."""

from __future__ import annotations

import pytest

from library.app.models import (
    ClipAssetBody,
    EntrySource,
    EntryStatus,
    LibraryEntryBody,
    PartOfSpeech,
)
from library.app.store import InMemoryLibraryStore


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


@pytest.mark.asyncio
async def test_a_stored_entry_is_found_by_its_sense_key() -> None:
    store = InMemoryLibraryStore()

    await store.upsert(_entry(), _asset())

    stored = await store.find("come", "arrive", PartOfSpeech.VERB)
    assert stored is not None
    assert stored.entry.id == "le_1"
    assert stored.asset.id == "clip_1"


@pytest.mark.asyncio
async def test_the_key_is_case_insensitive() -> None:
    store = InMemoryLibraryStore()
    await store.upsert(_entry(lemma="Come"), _asset())

    assert await store.find("come", "arrive", PartOfSpeech.VERB) is not None


@pytest.mark.asyncio
async def test_an_absent_key_is_a_miss() -> None:
    store = InMemoryLibraryStore()

    assert await store.find("come", "arrive", PartOfSpeech.VERB) is None


@pytest.mark.asyncio
async def test_a_regenerated_clip_replaces_the_entry_for_the_key() -> None:
    # A replacement supersedes what the key held; a retired entry is overwritten
    # rather than left beside its successor (FEAT-006).
    store = InMemoryLibraryStore()
    await store.upsert(_entry("le_old"), _asset("clip_old"))

    await store.upsert(_entry("le_new"), _asset("clip_new"))

    stored = await store.find("come", "arrive", PartOfSpeech.VERB)
    assert stored is not None
    assert stored.entry.id == "le_new"
    assert await store.get("le_old") is None


@pytest.mark.asyncio
async def test_a_status_change_moves_the_entry_and_keeps_the_key() -> None:
    store = InMemoryLibraryStore()
    await store.upsert(_entry(), _asset())

    updated = await store.set_status("le_1", EntryStatus.RETIRED)

    assert updated is not None
    assert updated.entry.status is EntryStatus.RETIRED
    stored = await store.find("come", "arrive", PartOfSpeech.VERB)
    assert stored is not None and stored.entry.status is EntryStatus.RETIRED


@pytest.mark.asyncio
async def test_an_unknown_entry_cannot_change_status() -> None:
    store = InMemoryLibraryStore()

    assert await store.set_status("le_missing", EntryStatus.RETIRED) is None


@pytest.mark.asyncio
async def test_a_candidate_is_held_beside_the_entry_and_promoted() -> None:
    # The clip regenerated for a reporting reader is held beside the serving clip
    # until a curator chooses it; promoting it makes it the clip served (FEAT-011).
    store = InMemoryLibraryStore()
    await store.upsert(_entry(), _asset("clip_1"))

    held = await store.set_candidate("le_1", _asset("clip_cand"))

    assert held is not None
    assert held.asset.id == "clip_1", "the serving clip is unchanged while a candidate is held"
    assert held.candidate is not None and held.candidate.id == "clip_cand"

    promoted = await store.promote_candidate("le_1")

    assert promoted is not None
    assert promoted.asset.id == "clip_cand"
    assert promoted.candidate is None
    found = await store.find("come", "arrive", PartOfSpeech.VERB)
    assert found is not None and found.asset.id == "clip_cand"


@pytest.mark.asyncio
async def test_a_status_change_keeps_the_held_candidate() -> None:
    store = InMemoryLibraryStore()
    await store.upsert(_entry(), _asset("clip_1"))
    await store.set_candidate("le_1", _asset("clip_cand"))

    updated = await store.set_status("le_1", EntryStatus.RETIRED)

    assert updated is not None and updated.candidate is not None
    assert updated.candidate.id == "clip_cand"


@pytest.mark.asyncio
async def test_an_unknown_entry_cannot_take_a_candidate() -> None:
    store = InMemoryLibraryStore()

    assert await store.set_candidate("le_missing", _asset()) is None


@pytest.mark.asyncio
async def test_promoting_without_a_candidate_is_none() -> None:
    store = InMemoryLibraryStore()
    await store.upsert(_entry(), _asset())

    assert await store.promote_candidate("le_1") is None

"""Lookup orchestration tests: the FEAT-003 acceptance criteria and edges."""

from __future__ import annotations

import pytest

from lookup.app.errors import (
    ClientLookupIdConflictError,
    EmptySelectionError,
    LookupNotFoundError,
    PhraseLimitExceededError,
)
from lookup.app.inventory import (
    InventoryUnavailableError,
    ResolvedWord,
    SenseInventory,
    build_default_inventory,
)
from lookup.app.library import InMemoryLibrary, LibraryClip, LibraryEntry, LibraryPort
from lookup.app.models import CreateLookupRequest, Kind, LookupStatus, PartOfSpeech
from lookup.app.service import (
    BEST_GUESS_NOTICE,
    INVENTORY_UNAVAILABLE_NOTICE,
    LookupService,
)
from lookup.app.store import InMemoryLookupStore


def _request(
    selection: str,
    *,
    consent: bool = True,
    client_id: str = "client-1",
    subject: str = "reader-1",
) -> CreateLookupRequest:
    return CreateLookupRequest(
        selection=selection,
        clientLookupId=client_id,
        platform="android",
        locale="en",
        consentModelProcessing=consent,
        subject=subject,
    )


def _service(
    inventory: SenseInventory | None = None,
    library: LibraryPort | None = None,
) -> LookupService:
    return LookupService(
        inventory=inventory if inventory is not None else build_default_inventory(),
        store=InMemoryLookupStore(),
        library=library if library is not None else InMemoryLibrary(),
    )


def _entry(entry_id: str, gloss: str) -> LibraryEntry:
    return LibraryEntry(
        id=entry_id,
        gloss_phrase=gloss,
        clip=LibraryClip(
            url=f"https://cdn.example/{entry_id}.mp4",
            duration_seconds=3.0,
            has_audio=False,
        ),
    )


def _seed_bank(library: InMemoryLibrary) -> None:
    library.add(
        "bank",
        "financial_institution",
        PartOfSpeech.NOUN,
        _entry("e-fin", "a business that keeps money for people"),
    )
    library.add(
        "bank",
        "river_edge",
        PartOfSpeech.NOUN,
        _entry("e-river", "the land along the side of a river"),
    )
    library.add(
        "bank",
        "tilt",
        PartOfSpeech.VERB,
        _entry("e-tilt", "to tilt an aircraft when turning"),
    )


class _UnavailableInventory:
    def resolve(self, token: str) -> ResolvedWord | None:
        raise InventoryUnavailableError("unavailable")


@pytest.mark.asyncio
async def test_an_inflected_form_uses_the_base_form_as_the_key() -> None:
    response = await _service().create_lookup(_request("coming"), "corr")

    assert response.kind == Kind.WORD
    assert response.normalisedLemma == "come"
    assert response.status == LookupStatus.GENERATING
    assert response.senses


@pytest.mark.asyncio
async def test_attached_punctuation_is_stripped_before_lookup() -> None:
    response = await _service().create_lookup(_request("coming,"), "corr")

    assert response.normalisedLemma == "come"
    assert response.rawSelection == "coming,"


@pytest.mark.asyncio
async def test_a_word_with_several_common_senses_carries_a_clip_each() -> None:
    library = InMemoryLibrary()
    _seed_bank(library)

    response = await _service(library=library).create_lookup(_request("bank"), "corr")

    assert response.status == LookupStatus.SERVED
    assert len(response.senses) >= 2
    assert all(sense.clip is not None for sense in response.senses)
    assert len({sense.entryId for sense in response.senses}) == len(response.senses)


@pytest.mark.asyncio
async def test_a_word_lookup_carries_a_sense_per_common_meaning() -> None:
    response = await _service().create_lookup(_request("light"), "corr")

    assert len(response.senses) >= 2
    assert all(sense.glossPhrase for sense in response.senses)


@pytest.mark.asyncio
async def test_a_word_absent_from_the_inventory_keeps_the_word_and_flags_a_best_guess() -> None:
    response = await _service().create_lookup(_request("zephyr"), "corr")

    assert response.normalisedLemma == "zephyr"
    assert response.notice == BEST_GUESS_NOTICE
    assert response.senses[0].partOfSpeech == PartOfSpeech.OTHER
    assert response.senses[0].entryId is None


@pytest.mark.asyncio
async def test_a_proper_noun_keeps_its_written_form() -> None:
    response = await _service().create_lookup(_request("Zephyr"), "corr")

    assert response.normalisedLemma == "Zephyr"
    assert response.notice == BEST_GUESS_NOTICE


@pytest.mark.asyncio
async def test_a_hyphenated_compound_keeps_its_written_form() -> None:
    response = await _service().create_lookup(_request("well-known"), "corr")

    assert response.normalisedLemma == "well-known"
    assert response.notice == BEST_GUESS_NOTICE


@pytest.mark.asyncio
async def test_a_two_to_six_word_selection_is_a_phrase() -> None:
    response = await _service().create_lookup(_request("kick the bucket"), "corr")

    assert response.kind == Kind.PHRASE
    assert response.normalisedLemma is None
    assert response.senses == []
    assert response.status == LookupStatus.GENERATING


@pytest.mark.asyncio
async def test_more_than_six_words_is_over_the_phrase_limit() -> None:
    with pytest.raises(PhraseLimitExceededError):
        await _service().create_lookup(_request("one two three four five six seven"), "corr")


@pytest.mark.asyncio
async def test_an_empty_selection_is_rejected() -> None:
    with pytest.raises(EmptySelectionError):
        await _service().create_lookup(_request("   "), "corr")


@pytest.mark.asyncio
async def test_a_punctuation_only_selection_resolves_empty() -> None:
    response = await _service().create_lookup(_request("..."), "corr")

    assert response.status == LookupStatus.EMPTY
    assert response.normalisedLemma is None
    assert response.senses == []


@pytest.mark.asyncio
async def test_without_consent_a_miss_is_denied() -> None:
    response = await _service().create_lookup(_request("zephyr", consent=False), "corr")

    assert response.status == LookupStatus.DENIED


@pytest.mark.asyncio
async def test_without_consent_a_library_hit_is_still_served() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )

    response = await _service(library=library).create_lookup(
        _request("coming", consent=False), "corr"
    )

    assert response.status == LookupStatus.SERVED


@pytest.mark.asyncio
async def test_an_unavailable_inventory_falls_back_to_the_word_as_the_key() -> None:
    response = await _service(inventory=_UnavailableInventory()).create_lookup(
        _request("coming"), "corr"
    )

    assert response.normalisedLemma == "coming"
    assert response.notice == INVENTORY_UNAVAILABLE_NOTICE


@pytest.mark.asyncio
async def test_a_repeated_client_id_replays_the_same_lookup() -> None:
    service = _service()

    first = await service.create_lookup(_request("coming", client_id="c-1"), "corr-1")
    second = await service.create_lookup(_request("coming", client_id="c-1"), "corr-2")

    assert first.lookupId == second.lookupId
    assert second.correlationId == "corr-2"


@pytest.mark.asyncio
async def test_a_reused_client_id_with_a_different_selection_conflicts() -> None:
    service = _service()
    await service.create_lookup(_request("coming", client_id="c-1"), "corr")

    with pytest.raises(ClientLookupIdConflictError):
        await service.create_lookup(_request("came", client_id="c-1"), "corr")


@pytest.mark.asyncio
async def test_a_lookup_is_visible_only_to_its_caller() -> None:
    service = _service()
    created = await service.create_lookup(_request("coming", subject="reader-1"), "corr")

    fetched = await service.get_lookup(created.lookupId, "reader-1", "corr-2")
    assert fetched.lookupId == created.lookupId

    with pytest.raises(LookupNotFoundError):
        await service.get_lookup(created.lookupId, "reader-2", "corr-3")


@pytest.mark.asyncio
async def test_an_unknown_lookup_id_is_not_found() -> None:
    with pytest.raises(LookupNotFoundError):
        await _service().get_lookup("lk_missing", "reader-1", "corr")

"""Lookup orchestration tests: the FEAT-003 acceptance criteria and edges."""

from __future__ import annotations

import pytest

from lookup.app.config import CLIP_MODEL_PIN
from lookup.app.entitlement import EntitlementPort
from lookup.app.errors import (
    ClientLookupIdConflictError,
    EmptySelectionError,
    LookupNotFoundError,
    PhraseLimitExceededError,
)
from lookup.app.generation import (
    GenerationJobStatus,
    GenerationUnavailableError,
    word_job_id,
)
from lookup.app.inventory import (
    InventoryUnavailableError,
    ResolvedWord,
    SenseInventory,
    build_default_inventory,
)
from lookup.app.library import (
    InMemoryLibrary,
    LibraryClip,
    LibraryEntry,
    LibraryEntryStatus,
    LibraryPort,
)
from lookup.app.models import CreateLookupRequest, Kind, LookupStatus, PartOfSpeech
from lookup.app.service import (
    GENERATION_FAILED_NOTICE,
    GENERATION_UNAVAILABLE_NOTICE,
    OUT_OF_INVENTORY_SENSE_LABEL,
    PHRASE_SENSE_LABEL,
    LookupService,
)
from lookup.app.store import InMemoryLookupStore
from lookup.tests.fakes import (
    RecordingEntitlementClient,
    RecordingGenerationClient,
    UnavailableLibrary,
    exhausted_meter,
    unavailable,
    unavailable_meter,
)


def _request(
    selection: str,
    *,
    consent: bool = True,
    client_id: str = "client-1",
    subject: str = "reader-1",
    is_anonymous: bool = False,
) -> CreateLookupRequest:
    return CreateLookupRequest(
        selection=selection,
        clientLookupId=client_id,
        platform="android",
        locale="en",
        consentModelProcessing=consent,
        subject=subject,
        isAnonymous=is_anonymous,
    )


def _service(
    inventory: SenseInventory | None = None,
    library: LibraryPort | None = None,
    generation: RecordingGenerationClient | None = None,
    entitlement: EntitlementPort | None = None,
    clip_model_pin: str = CLIP_MODEL_PIN,
    enable_phrase_clip: bool = True,
) -> LookupService:
    return LookupService(
        inventory=inventory if inventory is not None else build_default_inventory(),
        store=InMemoryLookupStore(),
        library=library if library is not None else InMemoryLibrary(),
        generation=generation if generation is not None else RecordingGenerationClient(),
        entitlement=entitlement if entitlement is not None else RecordingEntitlementClient(),
        clip_model_pin=clip_model_pin,
        enable_phrase_clip=enable_phrase_clip,
    )


def _entry(
    entry_id: str,
    gloss: str,
    *,
    status: LibraryEntryStatus = LibraryEntryStatus.ACTIVE,
) -> LibraryEntry:
    return LibraryEntry(
        id=entry_id,
        gloss_phrase=gloss,
        status=status,
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
async def test_a_word_absent_from_the_inventory_keeps_the_word_as_the_key() -> None:
    response = await _service().create_lookup(_request("zephyr"), "corr")

    assert response.normalisedLemma == "zephyr"
    # The meaning is never qualified for the reader: the lookup carries no
    # notice, and the sense label is a plain neutral string.
    assert response.notice is None
    assert response.senses[0].senseLabel == OUT_OF_INVENTORY_SENSE_LABEL
    assert response.senses[0].partOfSpeech == PartOfSpeech.OTHER
    assert response.senses[0].entryId is None


@pytest.mark.asyncio
async def test_a_proper_noun_keeps_its_written_form() -> None:
    response = await _service().create_lookup(_request("Zephyr"), "corr")

    assert response.normalisedLemma == "Zephyr"
    assert response.notice is None


@pytest.mark.asyncio
async def test_a_hyphenated_compound_keeps_its_written_form() -> None:
    response = await _service().create_lookup(_request("well-known"), "corr")

    assert response.normalisedLemma == "well-known"
    assert response.notice is None


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
    assert response.notice is None


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


@pytest.mark.asyncio
async def test_a_missing_word_sense_is_handed_to_the_generation_pipeline() -> None:
    generation = RecordingGenerationClient()

    response = await _service(generation=generation).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.GENERATING
    assert len(generation.jobs) == 1
    job = generation.jobs[0]
    assert job.kind == Kind.WORD
    assert job.lookup_id == response.lookupId
    assert job.lemma == "come"
    assert job.sense_label == "arrive"
    assert job.part_of_speech == PartOfSpeech.VERB
    # A word job leaves the phrase null: the pipeline generates the gloss phrase
    # via C-004 (C-003).
    assert job.phrase is None
    assert job.target_duration_seconds == 4.0
    assert job.model_pin == "gemini-omni-1.1-flash"


@pytest.mark.asyncio
async def test_a_configured_clip_pin_is_carried_onto_the_generation_job() -> None:
    generation = RecordingGenerationClient()

    response = await _service(
        generation=generation, clip_model_pin="gemini-omni-2.0-flash"
    ).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.GENERATING
    assert generation.jobs[0].model_pin == "gemini-omni-2.0-flash"


@pytest.mark.asyncio
async def test_two_lookups_for_the_same_missing_word_share_one_job() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)

    await service.create_lookup(_request("coming", client_id="c-1"), "corr")
    await service.create_lookup(_request("came", client_id="c-2"), "corr")

    assert len(generation.jobs) == 2
    assert generation.jobs[0].job_id == generation.jobs[1].job_id


@pytest.mark.asyncio
async def test_a_served_word_starts_no_generation() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )
    generation = RecordingGenerationClient()

    response = await _service(library=library, generation=generation).create_lookup(
        _request("coming"), "corr"
    )

    assert response.status == LookupStatus.SERVED
    assert generation.jobs == []


@pytest.mark.asyncio
async def test_a_served_phrase_carries_no_notice() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "a come"),
    )

    response = await _service(library=library).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.SERVED
    assert response.senses[0].glossPhrase == "a come"
    # How the phrase was produced is never shown to the reader.
    assert response.notice is None


@pytest.mark.asyncio
async def test_a_served_generated_phrase_carries_no_notice() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )

    response = await _service(library=library).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.SERVED
    assert response.notice is None


@pytest.mark.asyncio
async def test_a_poll_that_gains_a_phrase_carries_no_notice() -> None:
    library = InMemoryLibrary()
    service = _service(library=library)
    created = await service.create_lookup(_request("coming"), "corr")
    assert created.status == LookupStatus.GENERATING

    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "a come"),
    )
    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")
    again = await service.get_lookup(created.lookupId, "reader-1", "corr-3")

    assert polled.status == LookupStatus.SERVED
    assert polled.notice is None
    # A later poll of the already-served lookup stays notice-free.
    assert again.notice is None


@pytest.mark.asyncio
async def test_without_consent_a_miss_starts_no_generation() -> None:
    generation = RecordingGenerationClient()

    response = await _service(generation=generation).create_lookup(
        _request("zephyr", consent=False), "corr"
    )

    assert response.status == LookupStatus.DENIED
    assert generation.jobs == []


@pytest.mark.asyncio
async def test_a_pipeline_that_cannot_accept_the_job_shows_the_fallback() -> None:
    response = await _service(generation=unavailable()).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.FALLBACK
    assert response.notice == GENERATION_UNAVAILABLE_NOTICE
    # The word and phrase still show; only the clip is unavailable.
    assert response.normalisedLemma == "come"
    assert response.senses[0].glossPhrase == "to move toward or reach a place"


@pytest.mark.asyncio
async def test_a_generation_another_lookup_already_started_is_not_an_error() -> None:
    response = await _service(generation=RecordingGenerationClient(shared=True)).create_lookup(
        _request("coming"), "corr"
    )

    assert response.status == LookupStatus.GENERATING
    assert response.notice is None


@pytest.mark.asyncio
async def test_a_phrase_selection_is_handed_to_the_phrase_path() -> None:
    generation = RecordingGenerationClient()

    response = await _service(generation=generation).create_lookup(
        _request("kick the bucket"), "corr"
    )

    assert response.kind == Kind.PHRASE
    assert len(generation.jobs) == 1
    job = generation.jobs[0]
    assert job.kind == Kind.PHRASE
    assert job.lemma is None
    assert job.phrase == "kick the bucket"
    assert job.sense_label == PHRASE_SENSE_LABEL
    assert job.part_of_speech == PartOfSpeech.OTHER


@pytest.mark.asyncio
async def test_with_the_phrase_clip_flag_off_a_phrase_falls_back_to_the_word_path() -> None:
    # release.md "Rollout Phases & Feature Flags": the enable_phrase_clip kill
    # switch disables phrase clips, so a short phrase is not handed to the phrase
    # path; it falls back to the word path and is looked up as a single key.
    generation = RecordingGenerationClient()

    response = await _service(generation=generation, enable_phrase_clip=False).create_lookup(
        _request("kick the bucket"), "corr"
    )

    assert response.kind == Kind.WORD
    assert response.normalisedLemma == "kick the bucket"
    assert response.notice is None
    assert len(generation.jobs) == 1
    job = generation.jobs[0]
    assert job.kind == Kind.WORD
    assert job.lemma == "kick the bucket"
    # A word job leaves the phrase null; the pipeline generates the gloss phrase
    # via C-004 (C-003).
    assert job.phrase is None


@pytest.mark.asyncio
async def test_with_the_phrase_clip_flag_off_no_phrase_job_is_started() -> None:
    generation = RecordingGenerationClient()

    await _service(generation=generation, enable_phrase_clip=False).create_lookup(
        _request("kick the bucket"), "corr"
    )

    assert all(job.kind is Kind.WORD for job in generation.jobs)


@pytest.mark.asyncio
async def test_a_phrase_handed_to_generation_has_its_punctuation_stripped() -> None:
    generation = RecordingGenerationClient()

    response = await _service(generation=generation).create_lookup(
        _request("kick the bucket."), "corr"
    )

    assert response.rawSelection == "kick the bucket."
    assert generation.jobs[0].phrase == "kick the bucket"


@pytest.mark.asyncio
async def test_a_poll_serves_a_clip_the_library_gained_after_generation() -> None:
    library = InMemoryLibrary()
    service = _service(library=library)

    created = await service.create_lookup(_request("coming"), "corr")
    assert created.status == LookupStatus.GENERATING

    # The pipeline writes the finished word clip to the shared library.
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )
    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.SERVED
    assert polled.senses[0].clip is not None
    assert polled.senses[0].entryId == "e-come"


@pytest.mark.asyncio
async def test_a_poll_keeps_generating_while_the_clip_is_missing() -> None:
    service = _service()
    created = await service.create_lookup(_request("coming"), "corr")

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.GENERATING
    assert polled.senses[0].clip is None


@pytest.mark.asyncio
async def test_a_phrase_poll_stays_generating() -> None:
    service = _service()
    created = await service.create_lookup(_request("kick the bucket"), "corr")

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.kind == Kind.PHRASE
    assert polled.status == LookupStatus.GENERATING


@pytest.mark.asyncio
async def test_a_poll_consults_the_job_the_pipeline_was_given() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")

    await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert generation.status_calls == [word_job_id("come", "arrive", PartOfSpeech.VERB)]


@pytest.mark.asyncio
async def test_a_failed_generation_resolves_a_poll_to_the_fallback() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.FAILED

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.FALLBACK
    assert polled.notice == GENERATION_FAILED_NOTICE
    # The word and phrase still show; only the clip is unavailable.
    assert polled.normalisedLemma == "come"
    assert polled.senses[0].glossPhrase == "to move toward or reach a place"
    assert polled.senses[0].clip is None


@pytest.mark.asyncio
async def test_a_declined_generation_resolves_a_poll_to_the_fallback() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.DECLINED

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.FALLBACK
    assert polled.notice == GENERATION_FAILED_NOTICE


@pytest.mark.asyncio
async def test_a_job_the_pipeline_forgot_resolves_a_poll_to_the_fallback() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = None

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.FALLBACK


@pytest.mark.asyncio
async def test_a_generation_still_running_keeps_a_poll_generating() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.RUNNING

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.GENERATING


@pytest.mark.asyncio
async def test_a_status_consult_that_fails_keeps_a_poll_generating() -> None:
    generation = RecordingGenerationClient(status_error=GenerationUnavailableError("unreachable"))
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.GENERATING


@pytest.mark.asyncio
async def test_a_clip_gained_after_a_failed_generation_is_still_served() -> None:
    library = InMemoryLibrary()
    generation = RecordingGenerationClient()
    service = _service(library=library, generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.FAILED

    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )
    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.SERVED
    assert polled.senses[0].clip is not None


@pytest.mark.asyncio
async def test_a_failed_phrase_generation_resolves_a_poll_to_the_fallback() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("kick the bucket"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.DECLINED

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.kind == Kind.PHRASE
    assert polled.status == LookupStatus.FALLBACK
    assert polled.notice == GENERATION_FAILED_NOTICE


@pytest.mark.asyncio
async def test_a_failed_generation_stays_failed_on_a_later_poll() -> None:
    generation = RecordingGenerationClient()
    service = _service(generation=generation)
    created = await service.create_lookup(_request("coming"), "corr")
    generation.statuses[generation.jobs[0].job_id] = GenerationJobStatus.FAILED

    first = await service.get_lookup(created.lookupId, "reader-1", "corr-2")
    second = await service.get_lookup(created.lookupId, "reader-1", "corr-3")

    assert first.status == LookupStatus.FALLBACK
    assert second.status == LookupStatus.FALLBACK


@pytest.mark.asyncio
async def test_an_unreachable_library_falls_back_to_generation() -> None:
    # FEAT-006 edge: the library is unreachable, so the lookup serves the word and
    # phrase and requests a generation rather than failing the reader.
    generation = RecordingGenerationClient()

    response = await _service(library=UnavailableLibrary(), generation=generation).create_lookup(
        _request("coming"), "corr"
    )

    assert response.status == LookupStatus.GENERATING
    assert response.senses[0].clip is None
    assert response.senses[0].glossPhrase == "to move toward or reach a place"
    assert len(generation.jobs) == 1


@pytest.mark.asyncio
async def test_a_poll_with_an_unreachable_library_keeps_generating() -> None:
    service = _service(library=UnavailableLibrary())
    created = await service.create_lookup(_request("coming"), "corr")

    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.GENERATING
    assert polled.senses[0].clip is None


@pytest.mark.parametrize("status", [LibraryEntryStatus.RETIRED])
@pytest.mark.asyncio
async def test_a_retired_clip_is_not_served(status: LibraryEntryStatus) -> None:
    # FEAT-006: an entry retired after review is not served to new readers; a
    # generation is requested instead. An entry under review keeps serving, so
    # only a retired entry is a miss.
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "a stale meaning", status=status),
    )
    generation = RecordingGenerationClient()

    response = await _service(library=library, generation=generation).create_lookup(
        _request("coming"), "corr"
    )

    assert response.status == LookupStatus.GENERATING
    assert response.senses[0].clip is None
    assert response.senses[0].entryId is None
    assert len(generation.jobs) == 1


@pytest.mark.asyncio
async def test_a_retired_clip_regenerates_with_a_salted_job_id() -> None:
    # The pipeline refuses a repeated job id, so a miss that superseded a retired
    # entry salts its job id with that entry; otherwise the replacement could
    # never be generated (FEAT-006).
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-old", "a stale meaning", status=LibraryEntryStatus.RETIRED),
    )
    generation = RecordingGenerationClient()

    await _service(library=library, generation=generation).create_lookup(_request("coming"), "corr")

    job = generation.jobs[0]
    assert job.job_id == word_job_id("come", "arrive", PartOfSpeech.VERB, regeneration="e-old")
    assert job.job_id != word_job_id("come", "arrive", PartOfSpeech.VERB)


@pytest.mark.asyncio
async def test_a_replacement_entry_is_served_after_a_retirement() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-old", "a stale meaning", status=LibraryEntryStatus.RETIRED),
    )
    service = _service(library=library)
    created = await service.create_lookup(_request("coming"), "corr")
    assert created.status == LookupStatus.GENERATING

    # The pipeline's replacement is written over the retired entry.
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-new", "to move toward or reach a place"),
    )
    polled = await service.get_lookup(created.lookupId, "reader-1", "corr-2")

    assert polled.status == LookupStatus.SERVED
    assert polled.senses[0].entryId == "e-new"


# --- FEAT-013: the lookup path meters the allowance --------------------------


@pytest.mark.asyncio
async def test_a_signed_in_lookup_spends_one_unit_and_carries_the_allowance() -> None:
    meter = RecordingEntitlementClient(lookups_used=1, lookups_limit=20)

    response = await _service(entitlement=meter).create_lookup(_request("coming"), "corr")

    assert meter.calls == [("reader-1", "client-1")]
    assert response.allowance is not None
    assert response.allowance.used == 1
    assert response.allowance.limit == 20
    assert response.allowance.periodEnd == "2026-11-15T12:00:00+00:00"


@pytest.mark.asyncio
async def test_a_spent_allowance_resolves_to_the_fallback_with_no_clip() -> None:
    generation = RecordingGenerationClient()
    meter = exhausted_meter(limit=2)

    response = await _service(entitlement=meter, generation=generation).create_lookup(
        _request("coming"), "corr"
    )

    assert response.status == LookupStatus.FALLBACK
    assert response.allowance is not None
    # `used` equal to `limit` is the client's signal to offer a way to add more.
    assert response.allowance.used == response.allowance.limit == 2
    # The word and phrase still show; no clip is served or generated.
    assert response.normalisedLemma == "come"
    assert response.senses[0].glossPhrase == "to move toward or reach a place"
    assert response.senses[0].clip is None
    assert generation.jobs == []
    # The spent allowance is not charged again.
    assert meter.calls == [("reader-1", "client-1")]


@pytest.mark.asyncio
async def test_a_spent_allowance_withholds_a_library_clip() -> None:
    library = InMemoryLibrary()
    library.add(
        "come",
        "arrive",
        PartOfSpeech.VERB,
        _entry("e-come", "to move toward or reach a place"),
    )
    generation = RecordingGenerationClient()

    response = await _service(
        library=library, generation=generation, entitlement=exhausted_meter()
    ).create_lookup(_request("coming"), "corr")

    assert response.status == LookupStatus.FALLBACK
    assert response.senses[0].clip is None
    assert response.senses[0].entryId is None
    assert generation.jobs == []


@pytest.mark.asyncio
async def test_a_spent_allowance_resolves_a_phrase_lookup_to_the_fallback() -> None:
    meter = exhausted_meter(limit=2)

    response = await _service(entitlement=meter).create_lookup(_request("kick the bucket"), "corr")

    assert response.kind == Kind.PHRASE
    assert response.status == LookupStatus.FALLBACK
    assert response.senses == []
    assert response.allowance is not None
    assert response.allowance.used == response.allowance.limit == 2


@pytest.mark.asyncio
async def test_a_signed_out_reader_is_metered_on_the_device_and_carries_no_allowance() -> None:
    meter = RecordingEntitlementClient()

    response = await _service(entitlement=meter).create_lookup(
        _request("coming", is_anonymous=True), "corr"
    )

    # No account backs the guest, so the meter is never called and the allowance
    # is device-local (C-001).
    assert meter.calls == []
    assert response.allowance is None
    assert response.status == LookupStatus.GENERATING


@pytest.mark.asyncio
async def test_a_resent_lookup_spends_once_and_replays_its_allowance() -> None:
    meter = RecordingEntitlementClient(lookups_used=1, lookups_limit=20)
    service = _service(entitlement=meter)

    first = await service.create_lookup(_request("coming", client_id="c-1"), "corr-1")
    second = await service.create_lookup(_request("coming", client_id="c-1"), "corr-2")

    assert len(meter.calls) == 1
    assert first.lookupId == second.lookupId
    assert second.allowance == first.allowance


@pytest.mark.asyncio
async def test_an_unreachable_meter_does_not_block_the_reader() -> None:
    meter = unavailable_meter()

    response = await _service(entitlement=meter).create_lookup(_request("coming"), "corr")

    # The lookup proceeds on the grace path; the client reconciles the allowance
    # later (NFR-011).
    assert response.status == LookupStatus.GENERATING
    assert response.allowance is None


@pytest.mark.asyncio
async def test_a_lookup_is_validated_before_its_allowance_is_spent() -> None:
    meter = RecordingEntitlementClient()

    with pytest.raises(PhraseLimitExceededError):
        await _service(entitlement=meter).create_lookup(
            _request("one two three four five six seven"), "corr"
        )

    assert meter.calls == []


@pytest.mark.asyncio
async def test_an_empty_selection_is_not_metered() -> None:
    meter = RecordingEntitlementClient()

    response = await _service(entitlement=meter).create_lookup(_request("..."), "corr")

    assert response.status == LookupStatus.EMPTY
    assert response.allowance is None
    assert meter.calls == []

"""Generation-service tests: the FEAT-005 acceptance criteria and edge cases.

Covers the clip duration range, the background outcome for a decline, a timeout,
an unavailable provider, the one-job-per-word dedupe, and the generation budget.
"""

from __future__ import annotations

import pytest

from pipeline.app.clip_client import ClipDeclinedError, ClipTimeoutError, ClipUnavailableError
from pipeline.app.errors import (
    InvalidRequestError,
    JobAlreadyEnqueuedError,
    JobNotFoundError,
    MissingPhraseError,
    QueueUnavailableError,
    TargetDurationError,
)
from pipeline.app.models import JobStatus, Kind, PartOfSpeech
from pipeline.app.phrase_client import PhraseUnavailableError
from pipeline.tests.fakes import (
    FailingQueue,
    FakeClipGenerator,
    FakePhraseGenerator,
    FlakyLibraryWriter,
    clip,
    fallback_phrase_result,
    phrase,
    request,
    rig,
)


@pytest.mark.asyncio
async def test_submit_enqueues_the_job_and_returns_queued() -> None:
    test_rig = rig()

    response = await test_rig.service.submit(request())

    assert response.jobId == "job-1"
    assert response.status == "queued"
    stored = await test_rig.queue.get("job-1")
    assert stored is not None
    assert stored.status == JobStatus.QUEUED


@pytest.mark.asyncio
async def test_a_word_job_stores_a_clip_and_notifies_the_reader() -> None:
    test_rig = rig()
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert job.cost_units == 1.0
    assert job.completed_at is not None
    assert len(test_rig.generator.calls) == 1
    assert test_rig.generator.calls[0].phrase == "a key in the door"
    assert test_rig.generator.calls[0].model_pin == "gemini-omni-1.1-flash"
    stored = test_rig.library.find("key", "door_opener", PartOfSpeech.NOUN)
    assert stored is not None
    assert stored.entry.gloss_phrase == "a key in the door"
    assert stored.entry.gloss_phrase_is_fallback is False
    assert stored.entry.clip_asset_id == stored.asset.id
    assert stored.asset.duration_seconds == 3.0
    assert len(test_rig.notifier.ready) == 1


@pytest.mark.asyncio
async def test_the_job_records_both_pinned_models() -> None:
    # schema.md "GenerationJob": phraseModel and clipModel are both required.
    # D-018 pins them separately — the text model for the phrase and the video
    # model for the clip — so the job must not collapse them into one.
    test_rig = rig()
    await test_rig.service.submit(request())

    job = await test_rig.queue.get("job-1")

    assert job is not None
    assert job.phrase_model == "gemini-3.5-flash-lite"
    assert job.clip_model == "gemini-omni-1.1-flash"


@pytest.mark.asyncio
async def test_a_phrase_job_is_never_written_to_the_shared_library() -> None:
    test_rig = rig()
    await test_rig.service.submit(request(kind=Kind.PHRASE, lemma=None, phrase="kick the bucket"))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert test_rig.library.all() == ()
    assert len(test_rig.notifier.ready) == 1


@pytest.mark.asyncio
async def test_a_blank_phrase_is_rejected_before_any_generation() -> None:
    test_rig = rig()

    with pytest.raises(MissingPhraseError):
        await test_rig.service.submit(request(phrase="   "))

    assert test_rig.generator.calls == []


@pytest.mark.asyncio
async def test_a_word_job_without_a_phrase_generates_one_via_c004() -> None:
    # A word job arrives with a null phrase (C-003), so the pipeline asks the
    # model layer for the gloss phrase and generates the clip from it.
    test_rig = rig(phrase_generator=FakePhraseGenerator(phrase("a key in the door")))
    await test_rig.service.submit(request(phrase=None, sense_label="door_opener"))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert job.phrase == "a key in the door"
    assert len(test_rig.phrases.calls) == 1
    call = test_rig.phrases.calls[0]
    assert call.lemma == "key"
    assert call.part_of_speech == "noun"
    assert call.sense_hint == "door_opener"
    assert call.model_pin == "gemini-3.5-flash-lite"
    assert test_rig.generator.calls[0].phrase == "a key in the door"
    stored = test_rig.library.find("key", "door_opener", PartOfSpeech.NOUN)
    assert stored is not None
    assert stored.entry.gloss_phrase == "a key in the door"
    assert stored.entry.gloss_phrase_is_fallback is False


@pytest.mark.asyncio
async def test_a_phrase_job_uses_its_selection_and_asks_for_no_phrase() -> None:
    test_rig = rig()
    await test_rig.service.submit(request(kind=Kind.PHRASE, lemma=None, phrase="kick the bucket"))

    await test_rig.service.run("job-1")

    assert test_rig.phrases.calls == []
    assert test_rig.generator.calls[0].phrase == "kick the bucket"


@pytest.mark.asyncio
async def test_an_unreachable_phrase_model_is_substituted_with_the_fallback() -> None:
    # C-004 leaves the substitution to the caller on 503, so the phrase step
    # still hands the clip step a grammatical phrase rather than failing.
    test_rig = rig(
        phrase_generator=FakePhraseGenerator(error=PhraseUnavailableError("unavailable"))
    )
    await test_rig.service.submit(request(phrase=None, lemma="key"))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert test_rig.generator.calls[0].phrase == "a key"
    stored = test_rig.library.find("key", "door_opener", PartOfSpeech.NOUN)
    assert stored is not None
    assert stored.entry.gloss_phrase == "a key"
    # The pipeline substituted its own fallback, so the stored phrase is
    # recorded as the fallback for the view to mark as a best guess (FEAT-004).
    assert stored.entry.gloss_phrase_is_fallback is True


@pytest.mark.asyncio
async def test_the_model_layers_own_fallback_phrase_is_used() -> None:
    # A refusal, a timeout, or an unusable phrase comes back as a normal 200 with
    # source=fallback, so the pipeline carries that phrase through rather than
    # substituting its own — and records it as the fallback (FEAT-004).
    test_rig = rig(phrase_generator=FakePhraseGenerator(fallback_phrase_result("an ice")))
    await test_rig.service.submit(request(phrase=None, lemma="ice", sense_label="frozen_water"))

    await test_rig.service.run("job-1")

    assert test_rig.generator.calls[0].phrase == "an ice"
    stored = test_rig.library.find("ice", "frozen_water", PartOfSpeech.NOUN)
    assert stored is not None
    assert stored.entry.gloss_phrase_is_fallback is True


@pytest.mark.asyncio
async def test_an_empty_phrase_from_the_model_becomes_a_recorded_fallback() -> None:
    # An unusable output is the fallback path too (FEAT-004), so the pipeline
    # substitutes the template and records it as the fallback.
    test_rig = rig(phrase_generator=FakePhraseGenerator(phrase("   ")))
    await test_rig.service.submit(request(phrase=None, lemma="key", sense_label="door_opener"))

    await test_rig.service.run("job-1")

    assert test_rig.generator.calls[0].phrase == "a key"
    stored = test_rig.library.find("key", "door_opener", PartOfSpeech.NOUN)
    assert stored is not None
    assert stored.entry.gloss_phrase_is_fallback is True


@pytest.mark.asyncio
async def test_a_phrase_job_without_a_phrase_is_rejected() -> None:
    test_rig = rig()

    with pytest.raises(MissingPhraseError):
        await test_rig.service.submit(request(kind=Kind.PHRASE, lemma=None, phrase=None))

    assert test_rig.generator.calls == []


@pytest.mark.asyncio
async def test_a_target_over_four_seconds_is_rejected() -> None:
    test_rig = rig()

    with pytest.raises(TargetDurationError):
        await test_rig.service.submit(request(duration=5.0))


@pytest.mark.asyncio
async def test_a_non_positive_target_is_rejected() -> None:
    test_rig = rig()

    with pytest.raises(TargetDurationError):
        await test_rig.service.submit(request(duration=0.0))


@pytest.mark.asyncio
async def test_a_repeated_job_id_runs_one_generation() -> None:
    test_rig = rig()
    await test_rig.service.submit(request("job-1"))

    with pytest.raises(JobAlreadyEnqueuedError):
        await test_rig.service.submit(request("job-1", phrase="a key in the door"))

    assert len(test_rig.library.all()) == 0  # nothing ran yet
    assert test_rig.generator.calls == []


@pytest.mark.asyncio
async def test_an_unavailable_queue_is_reported() -> None:
    test_rig = rig(queue=FailingQueue())

    with pytest.raises(QueueUnavailableError):
        await test_rig.service.submit(request())


@pytest.mark.asyncio
async def test_a_library_write_failure_is_retried_and_the_clip_still_lands() -> None:
    # FEAT-006 edge: storage of a completed clip fails, but the reader still
    # receives the clip for this session and the write is retried.
    library = FlakyLibraryWriter(failures=1)
    test_rig = rig(library=library)
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert library.calls == 2
    assert library.find("key", "door_opener", PartOfSpeech.NOUN) is not None
    assert len(test_rig.notifier.ready) == 1


@pytest.mark.asyncio
async def test_a_library_that_never_accepts_the_write_does_not_fail_the_job() -> None:
    # The clip is delivered even when the write gives up: the reader comes first,
    # and the job is not marked failed for a storage failure on its own output.
    library = FlakyLibraryWriter(failures=99)
    test_rig = rig(library=library)
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert library.calls == 3  # the configured attempts
    assert library.all() == ()
    assert len(test_rig.notifier.ready) == 1


@pytest.mark.asyncio
async def test_a_declined_phrase_withholds_the_clip() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipDeclinedError("declined")))
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.DECLINED
    assert job.cost_units == 1.0
    assert test_rig.library.all() == ()
    assert test_rig.notifier.ready == []


@pytest.mark.asyncio
async def test_a_timeout_withholds_the_clip() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipTimeoutError("timeout")))
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert test_rig.library.all() == ()


@pytest.mark.asyncio
async def test_an_unavailable_provider_withholds_the_clip() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipUnavailableError("down")))
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert test_rig.library.all() == ()


@pytest.mark.asyncio
async def test_a_clip_over_the_four_second_cap_is_withheld() -> None:
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=4.5)))
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert test_rig.library.all() == ()
    assert test_rig.notifier.ready == []


@pytest.mark.asyncio
async def test_a_clip_at_the_cap_is_kept() -> None:
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=4.0)))
    await test_rig.service.submit(request(duration=4.0))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert len(test_rig.library.all()) == 1


@pytest.mark.asyncio
async def test_a_clip_below_the_three_second_floor_is_withheld() -> None:
    # The pinned model does not produce a clip shorter than three seconds, so an
    # out-of-range clip is withheld and the reader sees the fallback (FEAT-005).
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=2.5)))
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert test_rig.library.all() == ()
    assert test_rig.notifier.ready == []


@pytest.mark.asyncio
async def test_a_clip_at_the_floor_is_kept() -> None:
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=3.0)))
    await test_rig.service.submit(request(duration=3.0))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert len(test_rig.library.all()) == 1


@pytest.mark.asyncio
async def test_the_generation_budget_cap_stops_further_generation() -> None:
    test_rig = rig(budget=1.0)
    await test_rig.service.submit(request("job-1"))
    await test_rig.service.submit(request("job-2", lookup_id="lk_2"))

    first = await test_rig.service.run("job-1")
    second = await test_rig.service.run("job-2")

    assert first.status == JobStatus.SUCCEEDED
    assert second.status == JobStatus.FAILED
    assert second.cost_units == 0.0
    assert len(test_rig.generator.calls) == 1
    assert len(test_rig.library.all()) == 1


@pytest.mark.asyncio
async def test_the_generation_flag_off_stops_a_job_without_a_clip() -> None:
    # release.md "Rollout Phases & Feature Flags": the enable_generation kill
    # switch stops new generation, so the provider is never called and the job
    # ends without a clip for the caller to show as the fallback.
    test_rig = rig(enable_generation=False)
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert job.cost_units == 0.0
    assert test_rig.generator.calls == []
    assert test_rig.library.all() == ()
    assert test_rig.notifier.ready == []


@pytest.mark.asyncio
async def test_a_disabled_generation_still_accepts_the_enqueue() -> None:
    # The reader is never blocked: the enqueue is accepted (C-003 202) so the
    # lookup still returns the word and phrase while the job stops without a clip.
    test_rig = rig(enable_generation=False)

    response = await test_rig.service.submit(request())

    assert response.status == "queued"
    assert (await test_rig.service.get_status("job-1")).status == JobStatus.QUEUED


@pytest.mark.asyncio
async def test_the_phrase_clip_flag_off_stops_a_phrase_job_without_a_clip() -> None:
    # release.md "Rollout Phases & Feature Flags": the enable_phrase_clip kill
    # switch disables phrase clips, so a phrase job stops before any provider
    # call and the lookup resolves to the fallback.
    test_rig = rig(enable_phrase_clip=False)
    await test_rig.service.submit(request(kind=Kind.PHRASE, lemma=None, phrase="kick the bucket"))

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.FAILED
    assert job.cost_units == 0.0
    assert test_rig.generator.calls == []
    assert test_rig.phrases.calls == []
    assert test_rig.library.all() == ()
    assert test_rig.notifier.ready == []


@pytest.mark.asyncio
async def test_the_phrase_clip_flag_off_leaves_a_word_job_generating() -> None:
    # The kill switch disables phrase clips only; the word path keeps generating.
    test_rig = rig(enable_phrase_clip=False)
    await test_rig.service.submit(request())

    job = await test_rig.service.run("job-1")

    assert job.status == JobStatus.SUCCEEDED
    assert len(test_rig.generator.calls) == 1
    assert len(test_rig.library.all()) == 1


@pytest.mark.asyncio
async def test_a_disabled_phrase_clip_still_accepts_the_enqueue() -> None:
    # The reader is never blocked: the enqueue is accepted (C-003 202) so the
    # lookup still returns the phrase while the job stops without a clip.
    test_rig = rig(enable_phrase_clip=False)

    response = await test_rig.service.submit(
        request(kind=Kind.PHRASE, lemma=None, phrase="kick the bucket")
    )

    assert response.status == "queued"
    assert (await test_rig.service.get_status("job-1")).status == JobStatus.QUEUED


@pytest.mark.asyncio
async def test_running_an_unknown_job_is_an_invalid_request() -> None:
    with pytest.raises(InvalidRequestError):
        await rig().service.run("job-missing")


@pytest.mark.asyncio
async def test_a_job_reports_its_queued_state() -> None:
    test_rig = rig()
    await test_rig.service.submit(request())

    status = await test_rig.service.get_status("job-1")

    assert status.jobId == "job-1"
    assert status.lookupId == "lk_1"
    assert status.status == JobStatus.QUEUED


@pytest.mark.asyncio
async def test_a_declined_job_reports_declined() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipDeclinedError("declined")))
    await test_rig.service.submit(request())
    await test_rig.service.run("job-1")

    status = await test_rig.service.get_status("job-1")

    assert status.status == JobStatus.DECLINED


@pytest.mark.asyncio
async def test_a_failed_job_reports_failed() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipTimeoutError("timeout")))
    await test_rig.service.submit(request())
    await test_rig.service.run("job-1")

    status = await test_rig.service.get_status("job-1")

    assert status.status == JobStatus.FAILED


@pytest.mark.asyncio
async def test_the_state_of_an_unknown_job_is_not_found() -> None:
    with pytest.raises(JobNotFoundError):
        await rig().service.get_status("job-missing")

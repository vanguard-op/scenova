"""Retry tests for a word whose generation ended without a clip (FEAT-005; C-003, C-006).

The defect these protect against lived in the database. A generation job's row is
kept for good, so the id a word's first attempt used was never free again: every
later lookup computed the same id, was refused (C-003 409), and read that refusal
as *another lookup is already generating* — a word that failed once was
unservable forever. The tests run the lookup service against the pipeline's own
relational queue, the two store-backed sides joined at the queue, so the retry is
proved against the rows the defect lived in rather than a fake.

The real tables are the platform's migration history (`infra/db/migrations`); the
tests build the same shape from each service's model metadata, so the queries and
the row mapping are exercised without a database server.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from pipeline.app import db as pipeline_db
from pipeline.app.errors import JobAlreadyEnqueuedError, QueueUnavailableError
from pipeline.app.jobs import GenerationJob as PipelineJob
from pipeline.app.models import JobStatus as PipelineStatus
from pipeline.app.models import Kind as PipelineKind
from pipeline.app.models import PartOfSpeech as PipelinePartOfSpeech
from pipeline.app.queue import PostgresJobQueue
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

from lookup.app import db as lookup_db
from lookup.app.generation import (
    MAX_WORD_JOB_ATTEMPTS,
    GenerationAlreadyEnqueuedError,
    GenerationJob,
    GenerationJobStatus,
    GenerationUnavailableError,
    word_job_id,
)
from lookup.app.inventory import build_default_inventory
from lookup.app.library import InMemoryLibrary
from lookup.app.models import CreateLookupRequest, Kind, LookupStatus, PartOfSpeech
from lookup.app.service import GENERATION_FAILED_NOTICE, LookupService
from lookup.app.store import PostgresLookupStore
from lookup.tests.fakes import RecordingEntitlementClient

_T = "2026-10-15T12:00:00+00:00"
_WORD = ("come", "arrive", PartOfSpeech.VERB)


def _engine(tmp_path: Path) -> Engine:
    """One database holding both services' tables, as the primary database does."""

    engine = create_engine(f"sqlite:///{tmp_path / 'retry.db'}")
    lookup_db.Base.metadata.create_all(engine)
    pipeline_db.Base.metadata.create_all(engine)
    return engine


def _request(selection: str = "coming") -> CreateLookupRequest:
    return CreateLookupRequest(
        selection=selection,
        clientLookupId="client-1",
        platform="android",
        locale="en",
        consentModelProcessing=True,
        subject="reader-1",
    )


def _job(job_id: str, *, lookup_id: str = "lk_earlier") -> GenerationJob:
    return GenerationJob(
        job_id=job_id,
        lookup_id=lookup_id,
        kind=Kind.WORD,
        lemma=_WORD[0],
        phrase=None,
        sense_label=_WORD[1],
        part_of_speech=_WORD[2],
        target_duration_seconds=4.0,
        model_pin="gemini-omni-1.1-flash",
    )


def _pipeline_job(
    job: GenerationJob, *, status: PipelineStatus = PipelineStatus.QUEUED
) -> PipelineJob:
    """The lookup service's job as the pipeline's queue stores it (C-003)."""

    return PipelineJob(
        id=job.job_id,
        lookup_id=job.lookup_id,
        kind=PipelineKind(job.kind.value),
        lemma=job.lemma,
        phrase=job.phrase,
        sense_label=job.sense_label,
        part_of_speech=PipelinePartOfSpeech(job.part_of_speech.value),
        target_duration_seconds=job.target_duration_seconds,
        phrase_model="gemini-3.5-flash-lite",
        clip_model=job.model_pin,
        correlation_id="corr",
        status=status,
        attempts=job.attempt,
        cost_units=0.0,
        created_at=_T,
        completed_at=None,
    )


class _QueueBackedGeneration:
    """The lookup's generation port, wired straight to the pipeline's relational queue.

    In production the hop is HTTP (C-003, C-006); here the two store-backed sides
    are joined at the queue, so the persisted job rows and the queue's own
    repeated-id refusal — where the defect lived — are the real ones.
    """

    def __init__(self, queue: PostgresJobQueue) -> None:
        self._queue = queue

    async def enqueue(self, job: GenerationJob) -> None:
        try:
            await self._queue.enqueue(_pipeline_job(job))
        except JobAlreadyEnqueuedError as exc:
            raise GenerationAlreadyEnqueuedError("This generation is already enqueued.") from exc
        except QueueUnavailableError as exc:
            raise GenerationUnavailableError("The generation pipeline is unreachable.") from exc

    async def status(self, job_id: str) -> GenerationJobStatus | None:
        stored = await self._queue.get(job_id)
        return None if stored is None else GenerationJobStatus(stored.status.value)

    async def aclose(self) -> None:
        return None


async def _seed(queue: PostgresJobQueue, job_id: str, status: PipelineStatus) -> None:
    """A job row already on record, as an earlier attempt left it."""

    await queue.enqueue(_pipeline_job(_job(job_id), status=status))


def _job_count(engine: Engine) -> int:
    with engine.connect() as connection:
        return int(connection.execute(text("select count(*) from generation_jobs")).scalar_one())


def _service(engine: Engine, queue: PostgresJobQueue) -> tuple[LookupService, PostgresLookupStore]:
    store = PostgresLookupStore(engine)
    service = LookupService(
        inventory=build_default_inventory(),
        store=store,
        library=InMemoryLibrary(),
        generation=_QueueBackedGeneration(queue),
        entitlement=RecordingEntitlementClient(),
    )
    return service, store


@pytest.mark.asyncio
async def test_a_word_whose_generation_failed_is_attempted_again(tmp_path: Path) -> None:
    # A first attempt that ended without a clip holds its id for good, so the
    # later lookup must carry its own id rather than be read as still generating.
    engine = _engine(tmp_path)
    queue = PostgresJobQueue(engine)
    spent = word_job_id(*_WORD)
    await _seed(queue, spent, PipelineStatus.FAILED)
    service, store = _service(engine, queue)
    retry = word_job_id(*_WORD, attempt=1)
    try:
        created = await service.create_lookup(_request(), "corr")
        stored = await store.get(created.lookupId)
        retry_row = await queue.get(retry)
        spent_row = await queue.get(spent)
    finally:
        await service.aclose()
        await queue.aclose()

    assert created.status is LookupStatus.GENERATING
    assert retry_row is not None and retry_row.status is PipelineStatus.QUEUED
    assert retry_row.attempts == 1
    # Recovery works past the failed row, not by removing it.
    assert spent_row is not None and spent_row.status is PipelineStatus.FAILED
    assert stored is not None and stored.generation_job_ids == (retry,)


@pytest.mark.asyncio
async def test_a_generation_still_in_flight_is_shared_not_attempted_again(tmp_path: Path) -> None:
    # The attempt already running is the one both lookups are served by; a second
    # one would be a duplicate model call (FEAT-005 edge).
    engine = _engine(tmp_path)
    queue = PostgresJobQueue(engine)
    running = word_job_id(*_WORD)
    await _seed(queue, running, PipelineStatus.RUNNING)
    service, store = _service(engine, queue)
    try:
        created = await service.create_lookup(_request(), "corr")
        stored = await store.get(created.lookupId)
        count = _job_count(engine)
    finally:
        await service.aclose()
        await queue.aclose()

    assert created.status is LookupStatus.GENERATING
    assert created.notice is None
    assert count == 1
    assert stored is not None and stored.generation_job_ids == (running,)


@pytest.mark.asyncio
async def test_a_word_that_keeps_failing_settles_on_the_fallback(tmp_path: Path) -> None:
    # The bound stops a word that keeps failing from spending a model call on
    # every later lookup; it settles on the fallback instead of generating again.
    engine = _engine(tmp_path)
    queue = PostgresJobQueue(engine)
    for attempt in range(MAX_WORD_JOB_ATTEMPTS):
        await _seed(
            queue,
            word_job_id(*_WORD, attempt=attempt),
            PipelineStatus.DECLINED,
        )
    service, store = _service(engine, queue)
    try:
        created = await service.create_lookup(_request(), "corr")
        stored = await store.get(created.lookupId)
        count = _job_count(engine)
    finally:
        await service.aclose()
        await queue.aclose()

    assert created.status is LookupStatus.FALLBACK
    assert created.notice == GENERATION_FAILED_NOTICE
    # The word and phrase still show; only the clip is unavailable.
    assert created.normalisedLemma == "come"
    assert created.senses[0].clip is None
    assert count == MAX_WORD_JOB_ATTEMPTS, "no further attempt is spent"
    assert stored is not None and stored.status is LookupStatus.FALLBACK


def test_an_attempt_beyond_the_first_carries_its_own_job_id() -> None:
    first = word_job_id(*_WORD)
    second = word_job_id(*_WORD, attempt=1)

    assert first != second
    # The first attempt keeps the id concurrent lookups already share, so a
    # generation in flight is still found by every lookup of the same word.
    assert first == word_job_id(*_WORD, attempt=0)
    assert second != word_job_id(*_WORD, attempt=2)

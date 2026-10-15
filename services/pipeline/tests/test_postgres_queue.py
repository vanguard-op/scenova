"""Relational queue tests for generation jobs (FEAT-004, FEAT-005; C-003, C-006).

The relational queue is what the primary database holds, so these tests run the
same queue over an in-process relational engine: an enqueued job survives the
request that enqueued it and is read back whole — the schema's own fields and the
library key, clip target, and correlation id the pipeline generates with — a
duplicate jobId is refused rather than run twice, and an unreachable database is
reported as the queue being unavailable (schema.md "GenerationJob"; C-003, C-006).

The real table is the platform's migration history (`infra/db/migrations`); the
tests build the same shape from the queue's model metadata, so the queries and
the row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import replace
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

from pipeline.app.config import Settings
from pipeline.app.db import Base
from pipeline.app.errors import JobAlreadyEnqueuedError, QueueUnavailableError
from pipeline.app.jobs import GenerationJob
from pipeline.app.models import JobStatus, Kind, PartOfSpeech
from pipeline.app.queue import PostgresJobQueue, build_default_queue
from pipeline.tests.fakes import request, rig

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"

_T1 = "2026-10-15T12:00:00+00:00"
_T2 = "2026-10-15T12:00:05+00:00"


def _engine(tmp_path: Path, name: str = "pipeline.db") -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    return engine


@asynccontextmanager
async def _queue(engine: Engine) -> AsyncIterator[PostgresJobQueue]:
    queue = PostgresJobQueue(engine)
    try:
        yield queue
    finally:
        await queue.aclose()


def _job(job_id: str = "job-1") -> GenerationJob:
    return GenerationJob(
        id=job_id,
        lookup_id="lk_1",
        kind=Kind.WORD,
        lemma="key",
        phrase=None,
        sense_label="door_opener",
        part_of_speech=PartOfSpeech.NOUN,
        target_duration_seconds=3.0,
        phrase_model="gemini-3.5-flash-lite",
        clip_model="gemini-omni-1.1-flash",
        correlation_id="corr-1",
        status=JobStatus.QUEUED,
        attempts=1,
        cost_units=0.0,
        created_at=_T1,
        completed_at=None,
    )


@pytest.mark.asyncio
async def test_an_enqueued_job_is_read_back_whole(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _queue(engine) as queue:
        await queue.enqueue(_job())

        stored = await queue.get("job-1")

    assert stored is not None
    # schema.md "GenerationJob"
    assert stored.lookup_id == "lk_1"
    assert stored.kind is Kind.WORD
    assert stored.lemma == "key"
    assert stored.phrase is None
    assert stored.status is JobStatus.QUEUED
    assert stored.attempts == 1
    assert stored.phrase_model == "gemini-3.5-flash-lite"
    assert stored.clip_model == "gemini-omni-1.1-flash"
    assert stored.cost_units == 0.0
    assert stored.created_at == _T1
    assert stored.completed_at is None
    # The fields the pipeline generates with, which the entity does not carry
    assert stored.sense_label == "door_opener"
    assert stored.part_of_speech is PartOfSpeech.NOUN
    assert stored.target_duration_seconds == 3.0
    assert stored.correlation_id == "corr-1"


@pytest.mark.asyncio
async def test_a_duplicate_job_id_is_refused(tmp_path: Path) -> None:
    # C-003: a repeated jobId is a 409, so two concurrent lookups for the same
    # missing word share one generation rather than running it twice.
    engine = _engine(tmp_path)
    async with _queue(engine) as queue:
        await queue.enqueue(_job())
        with pytest.raises(JobAlreadyEnqueuedError):
            await queue.enqueue(_job())
        rows = _scalar_count(engine, "generation_jobs")

    assert rows == 1


@pytest.mark.asyncio
async def test_saving_a_job_records_its_outcome(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _queue(engine) as queue:
        await queue.enqueue(_job())
        running = await queue.get("job-1")
        assert running is not None
        await queue.save(
            replace(
                running,
                phrase="a key in the door",
                status=JobStatus.SUCCEEDED,
                cost_units=1.0,
                completed_at=_T2,
            )
        )

        stored = await queue.get("job-1")

    assert stored is not None
    assert stored.phrase == "a key in the door"
    assert stored.status is JobStatus.SUCCEEDED
    assert stored.cost_units == 1.0
    assert stored.completed_at == _T2


@pytest.mark.asyncio
async def test_an_unknown_job_reads_as_none(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _queue(engine) as queue:
        assert await queue.get("nobody") is None


@pytest.mark.asyncio
async def test_another_instance_finds_the_job_the_first_enqueued(tmp_path: Path) -> None:
    # C-006: the lookup service consults a job on a lookup poll, so a job
    # enqueued by one instance must be readable by another.
    engine = _engine(tmp_path)
    async with _queue(engine) as first:
        await first.enqueue(_job())

    async with _queue(engine) as second:
        stored = await second.get("job-1")

    assert stored is not None and stored.lookup_id == "lk_1"


@pytest.mark.asyncio
async def test_a_submitted_job_runs_from_the_database(tmp_path: Path) -> None:
    # The job is read back from the store before it runs, so the library key, the
    # clip target, and the correlation id must survive the round trip for the
    # phrase step, the clip call, and the generation events.
    engine = _engine(tmp_path)
    test_rig = rig(queue=PostgresJobQueue(engine))
    try:
        await test_rig.service.submit(request(phrase=None))
        queued = await test_rig.service.get_status("job-1")
        job = await test_rig.service.run("job-1")
    finally:
        await test_rig.service.aclose()

    assert queued.status is JobStatus.QUEUED
    assert job.status is JobStatus.SUCCEEDED
    call = test_rig.generator.calls[0]
    assert call.phrase == "a key in the door"
    assert call.target_duration_seconds == 3.0
    stored = test_rig.library.find("key", "door_opener", PartOfSpeech.NOUN)
    assert stored is not None
    assert test_rig.events.events[0].correlation_id


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_unavailable() -> None:
    queue = PostgresJobQueue(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(QueueUnavailableError):
            await queue.enqueue(_job())
    finally:
        await queue.aclose()


def test_the_default_queue_is_relational_when_a_database_is_configured(tmp_path: Path) -> None:
    url = f"sqlite:///{tmp_path / 'service.db'}"
    Base.metadata.create_all(create_engine(url))

    queue = build_default_queue(Settings(database_url=url))

    assert isinstance(queue, PostgresJobQueue)


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None


def _scalar_count(engine: Engine, table: str) -> int:
    with engine.connect() as connection:
        return int(connection.execute(text(f"select count(*) from {table}")).scalar_one())

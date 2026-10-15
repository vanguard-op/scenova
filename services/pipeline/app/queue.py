"""Job queue (schema "GenerationJob" persistence).

The queue accepts a job once, keyed by jobId, so a duplicate enqueue is refused
rather than run twice. Two implementations sit behind one port: the in-memory
queue the unit tests and a bare local run use, and the relational queue that is
the primary database (architecture.md "Primary Database"). A caller cannot tell
them apart.

An enqueue that cannot reach the database is reported as the queue being
unavailable, so the API answers 503 and the lookup resolves the reader to the
fallback (C-003); a jobId that is already enqueued is a 409 (C-003).
"""

from __future__ import annotations

import asyncio
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .db import GenerationJobRow, create_engine
from .errors import JobAlreadyEnqueuedError, QueueUnavailableError
from .jobs import GenerationJob
from .models import JobStatus, Kind, PartOfSpeech


class JobQueue(Protocol):
    """Port for generation-job persistence."""

    async def enqueue(self, job: GenerationJob) -> None: ...

    async def get(self, job_id: str) -> GenerationJob | None: ...

    async def save(self, job: GenerationJob) -> None: ...

    async def aclose(self) -> None:
        """Release whatever the queue holds open."""
        ...


class InMemoryJobQueue:
    """An in-memory queue keyed by jobId, with an atomic first-write check."""

    def __init__(self) -> None:
        self._jobs: dict[str, GenerationJob] = {}
        # Serialises the existence check and the write, so two concurrent
        # enqueues of the same jobId cannot both succeed.
        self._lock = asyncio.Lock()

    async def enqueue(self, job: GenerationJob) -> None:
        async with self._lock:
            if job.id in self._jobs:
                raise JobAlreadyEnqueuedError(f"Job {job.id} is already enqueued.")
            self._jobs[job.id] = job

    async def get(self, job_id: str) -> GenerationJob | None:
        return self._jobs.get(job_id)

    async def save(self, job: GenerationJob) -> None:
        async with self._lock:
            self._jobs[job.id] = job

    async def aclose(self) -> None:
        return None


class PostgresJobQueue:
    """Generation jobs in the primary relational database.

    The table is the platform's migration history (`infra/db/migrations`), so the
    queue maps it and never creates it. Each call runs its query on a worker
    thread, so a slow database never blocks the event loop a job runs on
    (NFR-006). Every failure to reach the database is reported as the queue being
    unavailable, so the enqueue answers 503 (C-003); a jobId that is already
    enqueued is a 409, decided by the row's primary key rather than by a
    check-then-write that two concurrent enqueues could both pass.
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def enqueue(self, job: GenerationJob) -> None:
        await asyncio.to_thread(self._enqueue, job)

    async def get(self, job_id: str) -> GenerationJob | None:
        return await asyncio.to_thread(self._get, job_id)

    async def save(self, job: GenerationJob) -> None:
        await asyncio.to_thread(self._save, job)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    def _enqueue(self, job: GenerationJob) -> None:
        try:
            with self._sessions() as session, session.begin():
                session.add(_row(job))
        except IntegrityError as exc:
            raise JobAlreadyEnqueuedError(f"Job {job.id} is already enqueued.") from exc
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _get(self, job_id: str) -> GenerationJob | None:
        try:
            with self._sessions() as session:
                row = session.scalar(select(GenerationJobRow).where(GenerationJobRow.id == job_id))
                return None if row is None else _job(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _save(self, job: GenerationJob) -> None:
        try:
            with self._sessions() as session, session.begin():
                row = session.get(GenerationJobRow, job.id)
                if row is None:
                    session.add(_row(job))
                else:
                    _apply(row, job)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def build_default_queue(settings: Settings) -> JobQueue:
    """The queue the pipeline runs on: the primary database when one is configured.

    An empty `DATABASE_URL` resolves to the in-memory queue, which the unit tests
    and a bare local run use; every deployed environment supplies it.
    """

    if settings.database_url is None:
        return InMemoryJobQueue()
    return PostgresJobQueue(create_engine(settings.database_url))


def _row(job: GenerationJob) -> GenerationJobRow:
    return GenerationJobRow(
        id=job.id,
        lookup_id=job.lookup_id,
        kind=job.kind.value,
        lemma=job.lemma,
        phrase=job.phrase,
        status=job.status.value,
        attempts=job.attempts,
        phrase_model=job.phrase_model,
        clip_model=job.clip_model,
        cost_units=job.cost_units,
        created_at=job.created_at,
        completed_at=job.completed_at,
        sense_label=job.sense_label,
        part_of_speech=job.part_of_speech.value,
        target_duration_seconds=job.target_duration_seconds,
        correlation_id=job.correlation_id,
    )


def _apply(row: GenerationJobRow, job: GenerationJob) -> None:
    row.lookup_id = job.lookup_id
    row.kind = job.kind.value
    row.lemma = job.lemma
    row.phrase = job.phrase
    row.status = job.status.value
    row.attempts = job.attempts
    row.phrase_model = job.phrase_model
    row.clip_model = job.clip_model
    row.cost_units = job.cost_units
    row.created_at = job.created_at
    row.completed_at = job.completed_at
    row.sense_label = job.sense_label
    row.part_of_speech = job.part_of_speech.value
    row.target_duration_seconds = job.target_duration_seconds
    row.correlation_id = job.correlation_id


def _job(row: GenerationJobRow) -> GenerationJob:
    return GenerationJob(
        id=row.id,
        lookup_id=row.lookup_id,
        kind=Kind(row.kind),
        lemma=row.lemma,
        phrase=row.phrase,
        sense_label=row.sense_label,
        part_of_speech=PartOfSpeech(row.part_of_speech),
        target_duration_seconds=row.target_duration_seconds,
        phrase_model=row.phrase_model,
        clip_model=row.clip_model,
        correlation_id=row.correlation_id,
        status=JobStatus(row.status),
        attempts=row.attempts,
        cost_units=row.cost_units,
        created_at=row.created_at,
        completed_at=row.completed_at,
    )


def _unavailable() -> QueueUnavailableError:
    return QueueUnavailableError("The generation queue is unavailable. Please try again.")

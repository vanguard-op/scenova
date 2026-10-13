"""Job queue (schema "GenerationJob" persistence).

The queue accepts a job once, keyed by jobId, so a duplicate enqueue is refused
rather than run twice. Jobs are held in memory for the foundations phase; Cloud
Tasks replaces this store behind the same port, and its failures surface as
`QueueUnavailableError` (C-003 503).
"""

from __future__ import annotations

import asyncio
from typing import Protocol

from .errors import JobAlreadyEnqueuedError
from .jobs import GenerationJob


class JobQueue(Protocol):
    """Port for generation-job persistence."""

    async def enqueue(self, job: GenerationJob) -> None: ...

    async def get(self, job_id: str) -> GenerationJob | None: ...

    async def save(self, job: GenerationJob) -> None: ...


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

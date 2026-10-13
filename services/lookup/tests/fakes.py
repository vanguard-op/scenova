"""Shared test doubles for the lookup tests."""

from __future__ import annotations

from lookup.app.generation import (
    GenerationAlreadyEnqueuedError,
    GenerationJob,
    GenerationJobStatus,
    GenerationUnavailableError,
)
from lookup.app.library import LibraryEntry, LibraryUnavailableError
from lookup.app.models import PartOfSpeech


class UnavailableLibrary:
    """A shared library that cannot be reached, as the shipped degradation allows.

    The lookup must treat an unreachable library as a miss and fall back to
    generation rather than failing the reader (FEAT-006 edge).
    """

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        raise LibraryUnavailableError("The shared library is unreachable.")

    async def aclose(self) -> None:
        return None


class RecordingGenerationClient:
    """A generation client that records every job, or refuses on demand.

    `error` stands in for an unavailable pipeline; `shared` stands in for the
    pipeline's 409 when another lookup already enqueued the same job. `statuses`
    maps a job id to the state the pipeline reports for it (C-006); an unknown id
    reports as still queued, and `status_error` stands in for an unreachable
    pipeline on a status consult.
    """

    def __init__(
        self,
        *,
        error: Exception | None = None,
        shared: bool = False,
        statuses: dict[str, GenerationJobStatus | None] | None = None,
        status_error: Exception | None = None,
    ) -> None:
        self.error = error if error is not None else None
        self.shared = shared
        self.jobs: list[GenerationJob] = []
        self.statuses = dict(statuses or {})
        self.status_error = status_error
        self.status_calls: list[str] = []

    async def enqueue(self, job: GenerationJob) -> None:
        if self.error is not None:
            raise self.error
        if self.shared:
            raise GenerationAlreadyEnqueuedError("This generation is already enqueued.")
        self.jobs.append(job)

    async def status(self, job_id: str) -> GenerationJobStatus | None:
        self.status_calls.append(job_id)
        if self.status_error is not None:
            raise self.status_error
        return self.statuses.get(job_id, GenerationJobStatus.QUEUED)

    async def aclose(self) -> None:
        return None


def unavailable() -> RecordingGenerationClient:
    """A generation client standing in for an unreachable pipeline."""

    return RecordingGenerationClient(error=GenerationUnavailableError("unreachable"))

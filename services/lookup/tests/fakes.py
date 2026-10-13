"""Shared test doubles for the lookup tests."""

from __future__ import annotations

from lookup.app.generation import (
    GenerationAlreadyEnqueuedError,
    GenerationJob,
    GenerationUnavailableError,
)


class RecordingGenerationClient:
    """A generation client that records every job, or refuses on demand.

    `error` stands in for an unavailable pipeline; `shared` stands in for the
    pipeline's 409 when another lookup already enqueued the same job.
    """

    def __init__(
        self,
        *,
        error: Exception | None = None,
        shared: bool = False,
    ) -> None:
        self.error = error if error is not None else None
        self.shared = shared
        self.jobs: list[GenerationJob] = []

    async def enqueue(self, job: GenerationJob) -> None:
        if self.error is not None:
            raise self.error
        if self.shared:
            raise GenerationAlreadyEnqueuedError("This generation is already enqueued.")
        self.jobs.append(job)

    async def aclose(self) -> None:
        return None


def unavailable() -> RecordingGenerationClient:
    """A generation client standing in for an unreachable pipeline."""

    return RecordingGenerationClient(error=GenerationUnavailableError("unreachable"))

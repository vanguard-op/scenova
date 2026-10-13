"""Client for the generation pipeline (C-003, C-006, FEAT-003, FEAT-005).

On a library miss the lookup service hands generation to the pipeline: a missing
word sense becomes a word job, and a short phrase becomes a phrase job. The
pipeline enqueues the job and returns 202 at once, so the lookup path waits only
for the hand-off — never for the clip — and the clip arrives asynchronously
(NFR-002, NFR-003). A word job carries no phrase, because the pipeline generates
the gloss phrase itself (C-004); a phrase job carries its selection.

Two lookups for the same missing word must share one generation, so a word job's
id is derived from the library key (lemma, sense, part of speech) rather than
from the lookup. The pipeline refuses a repeated job id with 409, which the
service reads as "already generating" instead of an error. The selected word is
personal data, so the id is an opaque digest of the key and never the word.

A generation can also end without a clip. On a later lookup poll the service
asks the pipeline for the job's state (C-006); a job that failed or was declined
resolves the reader's lookup to the fallback (FEAT-005).
"""

from __future__ import annotations

import hashlib
import logging
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol

import httpx2

from .models import Kind, PartOfSpeech

logger = logging.getLogger(__name__)

# The pinned model version every generation is measured against (architecture
# "Model Version & Fallback"); the lookup service passes it through to C-003.
DEFAULT_MODEL_PIN = "gemini-omni-1.1-flash"
# Clips are capped at four seconds, so a generation targets the cap.
CLIP_TARGET_SECONDS = 4.0


class GenerationUnavailableError(Exception):
    """The generation pipeline could not accept the job; the reader gets the fallback."""


class GenerationAlreadyEnqueuedError(Exception):
    """A job with this id is already enqueued; another lookup shares it."""


class GenerationJobStatus(StrEnum):
    """A generation job's state as the pipeline reports it (C-006)."""

    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    DECLINED = "declined"


@dataclass(frozen=True)
class GenerationJob:
    """A C-003 generation-job request."""

    job_id: str
    lookup_id: str
    kind: Kind
    lemma: str | None
    # A phrase job carries its selection; a word job leaves it null and the
    # pipeline generates the gloss phrase via C-004 (C-003).
    phrase: str | None
    sense_label: str
    part_of_speech: PartOfSpeech
    target_duration_seconds: float
    model_pin: str
    attempt: int = 0

    def to_payload(self) -> dict[str, object]:
        """The camelCase body the pipeline's C-003 endpoint expects."""

        return {
            "jobId": self.job_id,
            "lookupId": self.lookup_id,
            "kind": self.kind.value,
            "lemma": self.lemma,
            "phrase": self.phrase,
            "senseLabel": self.sense_label,
            "partOfSpeech": self.part_of_speech.value,
            "targetDurationSeconds": self.target_duration_seconds,
            "modelPin": self.model_pin,
            "attempt": self.attempt,
        }


class GenerationClient(Protocol):
    """Port for the generation pipeline (C-003, C-006)."""

    async def enqueue(self, job: GenerationJob) -> None:
        """Hand one job to the pipeline, or raise when it cannot be accepted."""
        ...

    async def status(self, job_id: str) -> GenerationJobStatus | None:
        """The pipeline's state for a job, or None when it knows no such job."""
        ...

    async def aclose(self) -> None: ...


def word_job_id(lemma: str, sense_label: str, part_of_speech: PartOfSpeech) -> str:
    """A stable job id for one missing word sense, so lookups share its generation."""

    return _digest(f"word:{lemma.casefold()}:{sense_label}:{part_of_speech.value}")


def phrase_job_id(lookup_id: str) -> str:
    """A job id for one phrase lookup; phrase clips are generated per request."""

    return _digest(f"phrase:{lookup_id}")


class HttpGenerationClient:
    """Calls the generation pipeline over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def enqueue(self, job: GenerationJob) -> None:
        try:
            response = await self._client.post(
                "/internal/generation-jobs",
                headers={"x-internal-audience": self._internal_audience},
                json=job.to_payload(),
            )
        except httpx2.HTTPError as exc:
            raise GenerationUnavailableError("The generation pipeline is unreachable.") from exc

        if response.status_code == 202:
            return
        if response.status_code == 409:
            raise GenerationAlreadyEnqueuedError("This generation is already enqueued.")
        logger.warning("generation enqueue refused with status %s", response.status_code)
        raise GenerationUnavailableError("The generation pipeline could not accept the job.")

    async def status(self, job_id: str) -> GenerationJobStatus | None:
        try:
            response = await self._client.get(
                f"/internal/generation-jobs/{job_id}",
                headers={"x-internal-audience": self._internal_audience},
            )
        except httpx2.HTTPError as exc:
            raise GenerationUnavailableError("The generation pipeline is unreachable.") from exc

        if response.status_code == 200:
            return _job_status(response)
        if response.status_code == 404:
            # The pipeline no longer knows the job; it has stopped for good.
            return None
        logger.warning("generation status refused with status %s", response.status_code)
        raise GenerationUnavailableError("The generation pipeline could not report the job.")

    async def aclose(self) -> None:
        await self._client.aclose()


def _job_status(response: httpx2.Response) -> GenerationJobStatus:
    try:
        return GenerationJobStatus(response.json()["status"])
    except (KeyError, TypeError, ValueError) as exc:
        raise GenerationUnavailableError("The pipeline returned an unreadable job.") from exc


def _digest(key: str) -> str:
    return "gen_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]

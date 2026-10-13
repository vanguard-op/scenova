"""Generation orchestration: enqueue a job, produce a clip, store it (FEAT-005).

A job carries the gloss phrase and the library key for a word sense. The service
calls the model-serving clip endpoint (C-005), writes a word clip to the shared
library, and notifies the reader when the clip is ready. The reader is never
blocked: `submit` enqueues and returns, and the job runs in the background.

A decline, a timeout, an unavailable provider, a clip over the four-second cap,
an exhausted generation budget, or the `enable_generation` kill switch being off
leaves no clip stored, so the caller shows the fallback.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Coroutine
from dataclasses import replace
from datetime import UTC, datetime
from typing import Any, Protocol
from uuid import uuid4

from .clip_client import (
    ClipDeclinedError,
    ClipGenerator,
    ClipResult,
    ClipTimeoutError,
    ClipUnavailableError,
    HttpClipClient,
)
from .config import Settings
from .errors import (
    InvalidRequestError,
    JobNotFoundError,
    MissingPhraseError,
    TargetDurationError,
)
from .jobs import ClipAsset, GenerationJob, LibraryEntry
from .library import InMemoryLibraryWriter, LibraryWriter
from .models import (
    CreateJobRequest,
    CreateJobResponse,
    JobStatus,
    JobStatusResponse,
    Kind,
)
from .notifier import LoggingNotifier, Notifier
from .queue import InMemoryJobQueue, JobQueue

logger = logging.getLogger(__name__)

# One provider clip call, normalised to a single unit for the generation-cost
# metric and the generation budget.
COST_UNITS_PER_CLIP = 1.0


class TaskSpawner(Protocol):
    """Schedules a job's background run without blocking the request."""

    def spawn(self, coro: Coroutine[Any, Any, None]) -> None: ...


class AsyncioTaskSpawner:
    """Runs a job on the event loop and holds a reference until it finishes."""

    def __init__(self) -> None:
        self._tasks: set[asyncio.Task[None]] = set()

    def spawn(self, coro: Coroutine[Any, Any, None]) -> None:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)


class GenerationService:
    """Turns an enqueued job into a stored clip, or leaves the caller the fallback."""

    def __init__(
        self,
        *,
        queue: JobQueue,
        clip_generator: ClipGenerator,
        library: LibraryWriter,
        notifier: Notifier,
        settings: Settings,
        spawner: TaskSpawner,
    ) -> None:
        self._queue = queue
        self._clip_generator = clip_generator
        self._library = library
        self._notifier = notifier
        self._settings = settings
        self._spawner = spawner
        # Guards the running generation-cost total across concurrent jobs.
        self._cost_lock = asyncio.Lock()
        self._cost_units = 0.0

    async def submit(self, request: CreateJobRequest) -> CreateJobResponse:
        """Validate, enqueue once, and hand the job to the background.

        The caller derives a stable jobId for a missing word, so two concurrent
        lookups for the same word collide on it and share one generation (C-003
        409 on a repeated jobId).
        """

        phrase = request.phrase.strip()
        if phrase == "":
            raise MissingPhraseError("The job carried no phrase to generate from.")
        duration = request.targetDurationSeconds
        if duration <= 0 or duration > self._settings.clip_max_duration_seconds:
            raise TargetDurationError(
                f"A clip target of {duration:g}s is outside the "
                f"{self._settings.clip_max_duration_seconds:g}-second cap."
            )
        job = GenerationJob(
            id=request.jobId,
            lookup_id=request.lookupId,
            kind=request.kind,
            lemma=request.lemma,
            phrase=phrase,
            sense_label=request.senseLabel,
            part_of_speech=request.partOfSpeech,
            target_duration_seconds=duration,
            provider_model=request.modelPin,
            status=JobStatus.QUEUED,
            attempts=request.attempt,
            cost_units=0.0,
            created_at=_now(),
            completed_at=None,
        )
        await self._queue.enqueue(job)
        self._spawner.spawn(self._run(job.id))
        return CreateJobResponse(jobId=job.id, status="queued")

    async def run(self, job_id: str) -> GenerationJob:
        """Run one job to its outcome. Exposed so the run can be driven directly."""

        job = await self._queue.get(job_id)
        if job is None:
            raise InvalidRequestError("No generation job exists for this id.")
        running = replace(job, status=JobStatus.RUNNING)
        await self._queue.save(running)

        if not self._settings.enable_generation:
            # The kill switch is off: stop before any provider call, so the job
            # ends without a clip and the reader's lookup resolves to the
            # fallback (release.md "Rollout Phases & Feature Flags").
            logger.info("generation is disabled; job %s stopped without a clip", running.id)
            return await self._finish(running, JobStatus.FAILED, 0.0)

        if not await self._admit():
            return await self._finish(running, JobStatus.FAILED, 0.0)

        try:
            clip = await self._clip_generator.generate(
                phrase=running.phrase,
                target_duration_seconds=running.target_duration_seconds,
                model_pin=running.provider_model,
            )
        except ClipDeclinedError:
            return await self._finish(running, JobStatus.DECLINED, COST_UNITS_PER_CLIP)
        except (ClipTimeoutError, ClipUnavailableError):
            return await self._finish(running, JobStatus.FAILED, COST_UNITS_PER_CLIP)

        if not _within_cap(clip, self._settings.clip_max_duration_seconds):
            logger.info("withheld a clip over the duration cap (job %s)", running.id)
            return await self._finish(running, JobStatus.FAILED, COST_UNITS_PER_CLIP)

        if running.kind is Kind.WORD:
            await self._store_word_clip(running, clip)
        await self._notifier.clip_ready(lookup_id=running.lookup_id, job_id=running.id, clip=clip)
        return await self._finish(running, JobStatus.SUCCEEDED, COST_UNITS_PER_CLIP)

    async def aclose(self) -> None:
        """Release the model client's connections."""

        await self._clip_generator.aclose()

    async def get_status(self, job_id: str) -> JobStatusResponse:
        """Report a job's state so a stalled generation can be resolved (C-006).

        The lookup service consults this on a lookup poll: a job that ends
        `failed` or `declined` never produced a clip, so the reader's lookup
        resolves to the fallback instead of waiting forever.
        """

        job = await self._queue.get(job_id)
        if job is None:
            raise JobNotFoundError("No generation job exists for this id.")
        return JobStatusResponse(jobId=job.id, lookupId=job.lookup_id, status=job.status)

    async def _admit(self) -> bool:
        """Reserve one clip call against the generation budget, if one is set."""

        cap = self._settings.generation_budget_units
        async with self._cost_lock:
            if cap > 0 and self._cost_units + COST_UNITS_PER_CLIP > cap:
                return False
            self._cost_units += COST_UNITS_PER_CLIP
            return True

    async def _store_word_clip(self, job: GenerationJob, clip: ClipResult) -> None:
        now = _now()
        asset = ClipAsset(
            id=clip.clip_id,
            duration_seconds=clip.duration_seconds,
            resolution="360p",
            storage_key=clip.storage_key,
            url=clip.url,
            has_audio=clip.has_audio,
            synth_id_watermark=clip.synth_id_watermark,
            created_at=now,
        )
        entry = LibraryEntry(
            id=f"le_{uuid4().hex}",
            lemma=job.lemma or job.phrase,
            part_of_speech=job.part_of_speech,
            sense_label=job.sense_label,
            gloss_phrase=job.phrase,
            clip_asset_id=asset.id,
            status="active",
            source="generated",
            created_at=now,
            updated_at=now,
        )
        await self._library.store(entry, asset)

    async def _finish(self, job: GenerationJob, status: JobStatus, cost: float) -> GenerationJob:
        finished = replace(job, status=status, cost_units=cost, completed_at=_now())
        await self._queue.save(finished)
        return finished

    async def _run(self, job_id: str) -> None:
        try:
            await self.run(job_id)
        except Exception:
            # A background job must never take the event loop down with it.
            logger.exception("generation job %s failed unexpectedly", job_id)


def build_default_service(settings: Settings) -> GenerationService:
    """Build the pipeline with its in-memory queue and library and the model client."""

    return GenerationService(
        queue=InMemoryJobQueue(),
        clip_generator=HttpClipClient(
            base_url=settings.model_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.model_timeout_seconds,
        ),
        library=InMemoryLibraryWriter(),
        notifier=LoggingNotifier(),
        settings=settings,
        spawner=AsyncioTaskSpawner(),
    )


def _within_cap(clip: ClipResult, cap: float) -> bool:
    return 0 < clip.duration_seconds <= cap


def _now() -> str:
    return datetime.now(UTC).isoformat()

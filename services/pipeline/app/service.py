"""Generation orchestration: enqueue a job, produce a clip, store it (FEAT-004, FEAT-005).

A word job arrives without a gloss phrase, so the service first asks the model
layer for one (C-004) and generates the clip from it; a phrase job carries its
selection and skips that step. It then calls the model-serving clip endpoint
(C-005), writes a word clip to the shared library, and notifies the reader when
the clip is ready. The reader is never blocked: `submit` enqueues and returns,
and the job runs in the background.

A decline, a timeout, an unavailable provider, a clip over the four-second cap,
an exhausted generation budget, or the `enable_generation` kill switch being off
leaves no clip stored, so the caller shows the fallback. The phrase step never
fails the job: the model layer's own fallback arrives as a normal result, and an
unreachable model layer is substituted with the fixed template.

Every job records the two pinned models the generation path depends on: the text
model that produced the gloss phrase and the video model the clip is generated
with. The generation events carry the clip model, since their cost, duration, and
resolution are the clip's.

Each job also records the three generation lifecycle events (EVT-007 to EVT-009).
A job stopped before it attempts generation — the kill switch or the budget
ceiling — records nothing, because it is not a generation that failed and must
not count against the generation-failure rate (`release.md`).
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable, Coroutine
from dataclasses import dataclass, replace
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
from .events import (
    REASON_DURATION_OVER_CAP,
    REASON_PROVIDER_DECLINED,
    REASON_PROVIDER_TIMEOUT,
    REASON_PROVIDER_UNAVAILABLE,
    REASON_UNEXPECTED_ERROR,
    GenerationEventEmitter,
    LoggingGenerationEventEmitter,
    generation_completed,
    generation_failed,
    generation_started,
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
from .phrase_client import (
    HttpPhraseClient,
    PhraseGenerator,
    PhraseUnavailableError,
)
from .phrase_fallback import fallback_phrase
from .pins import ModelPins
from .queue import InMemoryJobQueue, JobQueue

logger = logging.getLogger(__name__)

# One provider clip call, normalised to a single unit for the generation-cost
# metric and the generation budget.
COST_UNITS_PER_CLIP = 1.0

# The monotonic clock used to measure a generation's latency for EVT-008.
Clock = Callable[[], float]


@dataclass(frozen=True)
class ResolvedPhrase:
    """The gloss phrase a clip is generated from, and how it was produced.

    The origin travels with the phrase so the shared library entry records
    whether the stored phrase is the fallback template, letting the view that
    serves it mark the meaning as a best guess (FEAT-004).
    """

    phrase: str
    is_fallback: bool


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
        phrase_generator: PhraseGenerator,
        clip_generator: ClipGenerator,
        library: LibraryWriter,
        notifier: Notifier,
        settings: Settings,
        spawner: TaskSpawner,
        events: GenerationEventEmitter,
        clock: Clock | None = None,
    ) -> None:
        self._queue = queue
        self._phrase_generator = phrase_generator
        self._clip_generator = clip_generator
        self._library = library
        self._notifier = notifier
        self._settings = settings
        self._pins = ModelPins.from_settings(settings)
        self._spawner = spawner
        self._events = events
        self._clock = clock if clock is not None else time.monotonic
        # Guards the running generation-cost total across concurrent jobs.
        self._cost_lock = asyncio.Lock()
        self._cost_units = 0.0

    async def submit(
        self, request: CreateJobRequest, correlation_id: str | None = None
    ) -> CreateJobResponse:
        """Validate, enqueue once, and hand the job to the background.

        The caller derives a stable jobId for a missing word, so two concurrent
        lookups for the same word collide on it and share one generation (C-003
        409 on a repeated jobId). A phrase job must carry its selection; a word
        job leaves the phrase null and the pipeline generates it (C-004).
        """

        phrase = None if request.phrase is None else request.phrase.strip()
        if phrase == "":
            raise MissingPhraseError("The job carried no phrase to generate from.")
        if request.kind is Kind.PHRASE and phrase is None:
            raise MissingPhraseError("A phrase job needs a phrase to generate from.")
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
            phrase_model=self._pins.phrase.version,
            clip_model=request.modelPin,
            correlation_id=correlation_id or uuid4().hex,
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
            # fallback (release.md "Rollout Phases & Feature Flags"). No
            # generation event is recorded: generation was never attempted, so
            # the stop must not count against the generation-failure rate.
            logger.info("generation is disabled; job %s stopped without a clip", running.id)
            return await self._finish(running, JobStatus.FAILED, 0.0)

        if not await self._admit():
            # The budget ceiling is a capacity decision, not a provider failure,
            # so it is not recorded as a generation failure either.
            logger.info("generation budget exhausted; job %s stopped without a clip", running.id)
            return await self._finish(running, JobStatus.FAILED, 0.0)

        started_at = self._clock()
        self._events.emit(
            generation_started(
                correlation_id=running.correlation_id,
                job_id=running.id,
                lookup_id=running.lookup_id,
                kind=running.kind.value,
                model_version=running.clip_model,
            )
        )

        # A word job has no phrase yet, so the gloss phrase is generated first;
        # the phrase step never fails the job (C-004). Its origin travels with it
        # so the shared library entry records whether the phrase is the fallback.
        resolved = await self._resolve_phrase(running)
        phrase = resolved.phrase
        running = replace(running, phrase=phrase)

        try:
            clip = await self._clip_generator.generate(
                phrase=phrase,
                target_duration_seconds=running.target_duration_seconds,
                model_pin=running.clip_model,
            )
        except ClipDeclinedError:
            return await self._fail(
                running, JobStatus.DECLINED, COST_UNITS_PER_CLIP, REASON_PROVIDER_DECLINED
            )
        except ClipTimeoutError:
            return await self._fail(
                running, JobStatus.FAILED, COST_UNITS_PER_CLIP, REASON_PROVIDER_TIMEOUT
            )
        except ClipUnavailableError:
            return await self._fail(
                running, JobStatus.FAILED, COST_UNITS_PER_CLIP, REASON_PROVIDER_UNAVAILABLE
            )

        if not _within_cap(clip, self._settings.clip_max_duration_seconds):
            logger.info("withheld a clip over the duration cap (job %s)", running.id)
            return await self._fail(
                running, JobStatus.FAILED, COST_UNITS_PER_CLIP, REASON_DURATION_OVER_CAP
            )

        if running.kind is Kind.WORD:
            await self._store_word_clip(running, clip, phrase, resolved.is_fallback)
        await self._notifier.clip_ready(lookup_id=running.lookup_id, job_id=running.id, clip=clip)
        return await self._succeed(running, clip, started_at)

    async def aclose(self) -> None:
        """Release the model clients' connections."""

        await self._phrase_generator.aclose()
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

    async def _resolve_phrase(self, job: GenerationJob) -> ResolvedPhrase:
        """The phrase the clip is generated from: the job's own, or a C-004 gloss.

        A word job arrives without a phrase, so the pipeline asks the model layer
        for one. The model layer's own fallback is a normal result, so only
        unavailability leaves it as an error — and C-004 leaves the substitution
        to the caller, so the pipeline substitutes the fixed template rather than
        dropping the reader to a lookup with no phrase. Either way the origin is
        returned, so a fallback phrase is recorded as one (FEAT-004).
        """

        if job.phrase is not None:
            # A phrase job carries the reader's own selection, never a fallback.
            return ResolvedPhrase(job.phrase, False)

        try:
            result = await self._phrase_generator.generate(
                lemma=job.lemma,
                part_of_speech=job.part_of_speech.value,
                sense_hint=job.sense_label,
                model_pin=self._pins.phrase.version,
            )
        except PhraseUnavailableError:
            logger.info("phrase model unavailable; substituting the fallback (job %s)", job.id)
            return ResolvedPhrase(self._fallback_phrase(job), True)

        phrase = result.phrase.strip()
        if phrase == "":
            logger.info("phrase model returned no usable phrase (job %s)", job.id)
            return ResolvedPhrase(self._fallback_phrase(job), True)
        # C-004's source is the phrase's origin; the model layer's own fallback
        # arrives as a normal result, so it must be recorded as one.
        return ResolvedPhrase(phrase, result.source == "fallback")

    def _fallback_phrase(self, job: GenerationJob) -> str:
        return fallback_phrase(
            lemma=job.lemma,
            sense_hint=job.sense_label,
            part_of_speech=job.part_of_speech.value,
        )

    async def _admit(self) -> bool:
        """Reserve one clip call against the generation budget, if one is set."""

        cap = self._settings.generation_budget_units
        async with self._cost_lock:
            if cap > 0 and self._cost_units + COST_UNITS_PER_CLIP > cap:
                return False
            self._cost_units += COST_UNITS_PER_CLIP
            return True

    async def _store_word_clip(
        self, job: GenerationJob, clip: ClipResult, phrase: str, is_fallback: bool
    ) -> None:
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
            lemma=job.lemma or phrase,
            part_of_speech=job.part_of_speech,
            sense_label=job.sense_label,
            gloss_phrase=phrase,
            gloss_phrase_is_fallback=is_fallback,
            clip_asset_id=asset.id,
            status="active",
            source="generated",
            created_at=now,
            updated_at=now,
        )
        await self._library.store(entry, asset)

    async def _succeed(
        self, job: GenerationJob, clip: ClipResult, started_at: float
    ) -> GenerationJob:
        self._events.emit(
            generation_completed(
                correlation_id=job.correlation_id,
                job_id=job.id,
                lookup_id=job.lookup_id,
                model_version=job.clip_model,
                duration_ms=_elapsed_ms(started_at, self._clock()),
                cost_units=COST_UNITS_PER_CLIP,
                resolution=clip.resolution,
            )
        )
        return await self._finish(job, JobStatus.SUCCEEDED, COST_UNITS_PER_CLIP)

    async def _fail(
        self, job: GenerationJob, status: JobStatus, cost: float, reason: str
    ) -> GenerationJob:
        self._events.emit(
            generation_failed(
                correlation_id=job.correlation_id,
                job_id=job.id,
                lookup_id=job.lookup_id,
                reason=reason,
                model_version=job.clip_model,
            )
        )
        return await self._finish(job, status, cost)

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
            await self._record_unexpected(job_id)

    async def _record_unexpected(self, job_id: str) -> None:
        """Record an unexpected background failure as EVT-009.

        A job that raises before it reaches a defined outcome would otherwise
        leave the failure rate blind to it.
        """

        job = await self._queue.get(job_id)
        if job is None:
            return
        self._events.emit(
            generation_failed(
                correlation_id=job.correlation_id,
                job_id=job.id,
                lookup_id=job.lookup_id,
                reason=REASON_UNEXPECTED_ERROR,
                model_version=job.clip_model,
            )
        )


def build_default_service(settings: Settings) -> GenerationService:
    """Build the pipeline with its in-memory queue and library and the model client."""

    return GenerationService(
        queue=InMemoryJobQueue(),
        phrase_generator=HttpPhraseClient(
            base_url=settings.model_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.phrase_timeout_seconds,
        ),
        clip_generator=HttpClipClient(
            base_url=settings.model_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.model_timeout_seconds,
        ),
        library=InMemoryLibraryWriter(),
        notifier=LoggingNotifier(),
        settings=settings,
        spawner=AsyncioTaskSpawner(),
        events=LoggingGenerationEventEmitter(),
    )


def _within_cap(clip: ClipResult, cap: float) -> bool:
    return 0 < clip.duration_seconds <= cap


def _elapsed_ms(started_at: float, finished_at: float) -> int:
    return max(0, round((finished_at - started_at) * 1000))


def _now() -> str:
    return datetime.now(UTC).isoformat()

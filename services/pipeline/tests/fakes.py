"""Shared test doubles for the pipeline tests.

A fake clip generator, a recording notifier, a spawner that drops the background
run, and a rig that wires the service the same way the app does.
"""

from __future__ import annotations

from collections.abc import Coroutine
from dataclasses import dataclass
from typing import Any

from pipeline.app.clip_client import ClipResult
from pipeline.app.config import Settings
from pipeline.app.errors import QueueUnavailableError
from pipeline.app.events import GenerationEvent
from pipeline.app.jobs import GenerationJob
from pipeline.app.library import InMemoryLibraryWriter
from pipeline.app.models import CreateJobRequest, Kind, PartOfSpeech
from pipeline.app.queue import InMemoryJobQueue, JobQueue
from pipeline.app.service import Clock, GenerationService

MODEL_PIN = "gemini-omni-1.1-flash"


@dataclass
class _Call:
    """The arguments a fake generator was called with."""

    phrase: str
    target_duration_seconds: float
    model_pin: str


class FakeClipGenerator:
    """A clip generator that returns a fixed clip or raises a fixed error."""

    def __init__(
        self,
        result: ClipResult | None = None,
        error: Exception | None = None,
    ) -> None:
        self.result = result if result is not None else clip()
        self.error = error
        self.calls: list[_Call] = []

    async def generate(
        self, *, phrase: str, target_duration_seconds: float, model_pin: str
    ) -> ClipResult:
        self.calls.append(_Call(phrase, target_duration_seconds, model_pin))
        if self.error is not None:
            raise self.error
        return self.result

    async def aclose(self) -> None:
        return None


class RecordingNotifier:
    """A notifier that records every ready event."""

    def __init__(self) -> None:
        self.ready: list[tuple[str, str, ClipResult]] = []

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None:
        self.ready.append((lookup_id, job_id, clip))


class NullSpawner:
    """A spawner that closes the background run without executing it."""

    def spawn(self, coro: Coroutine[Any, Any, None]) -> None:
        coro.close()


class RecordingEmitter:
    """A generation-event emitter that records every event, in order."""

    def __init__(self) -> None:
        self.events: list[GenerationEvent] = []

    def emit(self, event: GenerationEvent) -> None:
        self.events.append(event)


class FakeClock:
    """A monotonic clock that returns each reading in turn.

    A test passes the start and end readings it wants, so a measured duration is
    exact rather than wall-clock dependent.
    """

    def __init__(self, *readings: float) -> None:
        self._readings = list(readings)
        self._last = readings[-1] if readings else 0.0

    def __call__(self) -> float:
        if self._readings:
            self._last = self._readings.pop(0)
        return self._last


class FailingQueue(InMemoryJobQueue):
    """A queue that refuses every enqueue, as an unavailable queue would."""

    async def enqueue(self, job: GenerationJob) -> None:
        raise QueueUnavailableError("The queue is unavailable.")


@dataclass
class Rig:
    """The service under test with the doubles it was built from."""

    service: GenerationService
    generator: FakeClipGenerator
    library: InMemoryLibraryWriter
    notifier: RecordingNotifier
    queue: JobQueue
    events: RecordingEmitter


def clip(duration_seconds: float = 3.0) -> ClipResult:
    return ClipResult(
        clip_id="clip-1",
        storage_key="clips/clip-1.mp4",
        url="https://cdn.example/clip-1.mp4",
        duration_seconds=duration_seconds,
        resolution="360p",
        has_audio=False,
        synth_id_watermark=True,
    )


def request(
    job_id: str = "job-1",
    *,
    phrase: str = "a key in the door",
    kind: Kind = Kind.WORD,
    lemma: str | None = "key",
    sense_label: str = "door_opener",
    part_of_speech: PartOfSpeech = PartOfSpeech.NOUN,
    duration: float = 3.0,
    lookup_id: str = "lk_1",
    attempt: int = 1,
) -> CreateJobRequest:
    return CreateJobRequest(
        jobId=job_id,
        lookupId=lookup_id,
        kind=kind,
        lemma=lemma,
        phrase=phrase,
        senseLabel=sense_label,
        partOfSpeech=part_of_speech,
        targetDurationSeconds=duration,
        modelPin=MODEL_PIN,
        attempt=attempt,
    )


def rig(
    *,
    generator: FakeClipGenerator | None = None,
    queue: JobQueue | None = None,
    budget: float = 0.0,
    enable_generation: bool = True,
    clock: Clock | None = None,
) -> Rig:
    resolved_generator = generator if generator is not None else FakeClipGenerator()
    resolved_queue = queue if queue is not None else InMemoryJobQueue()
    library = InMemoryLibraryWriter()
    notifier = RecordingNotifier()
    events = RecordingEmitter()
    service = GenerationService(
        queue=resolved_queue,
        clip_generator=resolved_generator,
        library=library,
        notifier=notifier,
        settings=Settings(generation_budget_units=budget, enable_generation=enable_generation),
        spawner=NullSpawner(),
        events=events,
        clock=clock,
    )
    return Rig(
        service=service,
        generator=resolved_generator,
        library=library,
        notifier=notifier,
        queue=resolved_queue,
        events=events,
    )

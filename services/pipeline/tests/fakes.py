"""Shared test doubles for the pipeline tests.

A fake phrase generator, a fake clip generator, a recording notifier, a spawner
that drops the background run, and a rig that wires the service the same way the
app does.
"""

from __future__ import annotations

from collections.abc import Coroutine
from dataclasses import dataclass
from typing import Any

from pipeline.app.clip_client import ClipResult
from pipeline.app.config import Settings
from pipeline.app.errors import QueueUnavailableError
from pipeline.app.events import GenerationEvent
from pipeline.app.jobs import ClipAsset, GenerationJob, LibraryEntry
from pipeline.app.library import InMemoryLibraryWriter, LibraryUnavailableError
from pipeline.app.models import CreateJobRequest, Kind, PartOfSpeech
from pipeline.app.phrase_client import PhraseResult
from pipeline.app.queue import InMemoryJobQueue, JobQueue
from pipeline.app.service import Clock, GenerationService

MODEL_PIN = "gemini-omni-1.1-flash"


@dataclass
class _Call:
    """The arguments a fake generator was called with."""

    phrase: str
    target_duration_seconds: float
    model_pin: str


@dataclass
class _PhraseCall:
    """The arguments the fake phrase generator was called with."""

    lemma: str | None
    part_of_speech: str
    sense_hint: str
    model_pin: str


class FakePhraseGenerator:
    """A phrase generator that returns a fixed phrase or raises a fixed error."""

    def __init__(
        self,
        result: PhraseResult | None = None,
        error: Exception | None = None,
    ) -> None:
        self.result = result if result is not None else phrase()
        self.error = error
        self.calls: list[_PhraseCall] = []

    async def generate(
        self,
        *,
        lemma: str | None,
        part_of_speech: str,
        sense_hint: str,
        model_pin: str,
    ) -> PhraseResult:
        self.calls.append(_PhraseCall(lemma, part_of_speech, sense_hint, model_pin))
        if self.error is not None:
            raise self.error
        return self.result

    async def aclose(self) -> None:
        return None


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

    async def aclose(self) -> None:
        return None


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


class FlakyLibraryWriter(InMemoryLibraryWriter):
    """A library that refuses a number of writes before accepting them.

    Stands in for a library outage that recovers partway through the retry, so a
    test can prove the write is retried and the clip is still delivered (FEAT-006).
    """

    def __init__(self, failures: int) -> None:
        super().__init__()
        self.failures_remaining = failures
        self.calls = 0

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None:
        self.calls += 1
        if self.failures_remaining > 0:
            self.failures_remaining -= 1
            raise LibraryUnavailableError("The shared library is unreachable.")
        await super().store(entry, asset)


@dataclass
class Rig:
    """The service under test with the doubles it was built from."""

    service: GenerationService
    phrases: FakePhraseGenerator
    generator: FakeClipGenerator
    library: InMemoryLibraryWriter
    notifier: RecordingNotifier
    queue: JobQueue
    events: RecordingEmitter


def phrase(text: str = "a key in the door") -> PhraseResult:
    """A generated phrase, as C-004 returns on a good call."""

    return PhraseResult(phrase=text, source="generated", best_guess=False)


def fallback_phrase_result(text: str = "a key") -> PhraseResult:
    """The model layer's own fallback, as C-004 returns it on a refusal."""

    return PhraseResult(phrase=text, source="fallback", best_guess=True)


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
    phrase: str | None = "a key in the door",
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
    phrase_generator: FakePhraseGenerator | None = None,
    queue: JobQueue | None = None,
    library: InMemoryLibraryWriter | None = None,
    budget: float = 0.0,
    enable_generation: bool = True,
    enable_phrase_clip: bool = True,
    library_retry_delay_seconds: float = 0.0,
    clock: Clock | None = None,
) -> Rig:
    resolved_generator = generator if generator is not None else FakeClipGenerator()
    resolved_phrases = phrase_generator if phrase_generator is not None else FakePhraseGenerator()
    resolved_queue = queue if queue is not None else InMemoryJobQueue()
    resolved_library = library if library is not None else InMemoryLibraryWriter()
    notifier = RecordingNotifier()
    events = RecordingEmitter()
    service = GenerationService(
        queue=resolved_queue,
        phrase_generator=resolved_phrases,
        clip_generator=resolved_generator,
        library=resolved_library,
        notifier=notifier,
        settings=Settings(
            generation_budget_units=budget,
            enable_generation=enable_generation,
            enable_phrase_clip=enable_phrase_clip,
            library_store_retry_delay_seconds=library_retry_delay_seconds,
        ),
        spawner=NullSpawner(),
        events=events,
        clock=clock,
    )
    return Rig(
        service=service,
        phrases=resolved_phrases,
        generator=resolved_generator,
        library=resolved_library,
        notifier=notifier,
        queue=resolved_queue,
        events=events,
    )

"""Producers: turn a golden-set item into a model-backed output (C-004, C-005).

A producer is the run's model call. It goes through the real generation path —
the same `PhraseService` and `ClipService` the internal endpoints use — so the
evaluation measures the behaviour that ships, not a parallel copy of it. A
provider failure is captured as a failed outcome rather than raised, so the judge
sees the same refusal, timeout, and unavailability the reader's fallback hides.

A recorded run can be replayed offline: `ReplayProducer` feeds back the outputs a
previous live run wrote, so the same judge and score can be reproduced without a
provider credential.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from typing import TypedDict

from app.clip.service import ClipRequest, ClipService
from app.clip.store import ClipStorageError, GcsClipStore
from app.config import Settings
from app.data import load_common_words
from app.phrase.service import PhraseRequest, PhraseService
from app.prompt import DEFAULT_CLIP_PROMPT_PATH, load_prompt
from app.provider import (
    ClipModel,
    GeminiClipModel,
    GeminiPhraseModel,
    PhraseModel,
    ProviderRefusal,
    ProviderTimeout,
    ProviderUnavailable,
)

from .bar import ItemKey

__all__ = [
    "ClipOutcome",
    "ClipProducer",
    "PhraseOutcome",
    "PhraseProducer",
    "Producer",
    "ReplayMiss",
    "ReplayProducer",
    "live_clip_producer",
    "live_phrase_producer",
]


class PhraseOutcome(TypedDict):
    """What one gloss-phrase call produced (the judged output for NFR-050)."""

    phrase: str
    source: str
    bestGuess: bool
    failed: bool
    reason: str | None


class ClipOutcome(TypedDict):
    """What one clip call produced (the judged output for NFR-051, NFR-053)."""

    produced: bool
    durationSeconds: float | None
    resolution: str | None
    hasAudio: bool | None
    synthIdWatermark: bool | None
    reason: str | None


Producer = Callable[[Mapping[str, object]], Awaitable[Mapping[str, object]]]


class ReplayMiss(Exception):
    """A recorded run has no output for one golden-set item."""


def _text(item: Mapping[str, object], field: str) -> str:
    value = item.get(field)
    return value if isinstance(value, str) else ""


class PhraseProducer:
    """Produces one gloss phrase per golden-set item (FEAT-004)."""

    def __init__(self, service: PhraseService, *, model_pin: str) -> None:
        self._service = service
        self._model_pin = model_pin

    async def __call__(self, item: Mapping[str, object]) -> PhraseOutcome:
        request = PhraseRequest(
            lemma=_text(item, "lemma") or None,
            part_of_speech=_text(item, "partOfSpeech"),
            sense_hint=_text(item, "senseHint"),
            model_pin=self._model_pin,
        )
        try:
            result = await self._service.generate(request)
        except ProviderUnavailable as exc:
            return PhraseOutcome(
                phrase="",
                source="fallback",
                bestGuess=True,
                failed=True,
                reason=f"provider unavailable: {exc}",
            )
        return PhraseOutcome(
            phrase=result.phrase,
            source=result.source,
            bestGuess=result.best_guess,
            failed=False,
            reason=None,
        )


class ClipProducer:
    """Produces one clip per golden-set item (FEAT-005, FEAT-007)."""

    def __init__(
        self,
        service: ClipService,
        *,
        model_pin: str,
        target_duration_seconds: float = 4.0,
    ) -> None:
        self._service = service
        self._model_pin = model_pin
        self._target_duration_seconds = target_duration_seconds

    async def __call__(self, item: Mapping[str, object]) -> ClipOutcome:
        request = ClipRequest(
            phrase=_text(item, "phrase"),
            target_duration_seconds=self._target_duration_seconds,
            model_pin=self._model_pin,
        )
        try:
            result = await self._service.generate(request)
        except ProviderRefusal:
            return _no_clip("declined")
        except ProviderTimeout:
            return _no_clip("timeout")
        except ProviderUnavailable:
            return _no_clip("unavailable")
        except ClipStorageError:
            return _no_clip("storage")
        return ClipOutcome(
            produced=True,
            durationSeconds=result.duration_seconds,
            resolution=result.resolution,
            hasAudio=result.has_audio,
            synthIdWatermark=result.synth_id_watermark,
            reason=None,
        )


def _no_clip(reason: str) -> ClipOutcome:
    return ClipOutcome(
        produced=False,
        durationSeconds=None,
        resolution=None,
        hasAudio=None,
        synthIdWatermark=None,
        reason=reason,
    )


class ReplayProducer:
    """Feeds back the outputs a recorded run wrote, keyed by item identity."""

    def __init__(self, key: ItemKey, outcomes: Mapping[str, Mapping[str, object]]) -> None:
        self._key = key
        self._outcomes = outcomes

    async def __call__(self, item: Mapping[str, object]) -> dict[str, object]:
        identity = self._key(item)
        try:
            recorded = self._outcomes[identity]
        except KeyError as exc:
            raise ReplayMiss(f"no recorded output for {identity}") from exc
        return dict(recorded)


def live_phrase_producer(settings: Settings) -> PhraseProducer:
    """A producer wired to the pinned provider through the shipped phrase path."""

    model: PhraseModel = GeminiPhraseModel(settings)
    service = PhraseService(
        model=model,
        prompt=load_prompt(),
        common_words=load_common_words(),
        settings=settings,
    )
    return PhraseProducer(service, model_pin=settings.model_pin)


def live_clip_producer(settings: Settings, *, target_duration_seconds: float = 4.0) -> ClipProducer:
    """A producer wired to the pinned provider through the shipped clip path."""

    model: ClipModel = GeminiClipModel(settings)
    service = ClipService(
        model=model,
        store=GcsClipStore(settings),
        prompt=load_prompt(DEFAULT_CLIP_PROMPT_PATH),
        settings=settings,
    )
    return ClipProducer(
        service,
        model_pin=settings.model_pin,
        target_duration_seconds=target_duration_seconds,
    )

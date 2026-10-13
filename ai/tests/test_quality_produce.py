"""Producers: a golden item becomes a model call, and a provider failure is captured.

The provider is faked, so these stay deterministic and offline. The live run
against the pinned model is the gate's job.
"""

from __future__ import annotations

import pytest
from app.provider import ProviderRefusal, ProviderTimeout, ProviderUnavailable
from helpers import (
    CLIP_BYTES,
    CLIP_PIN,
    PHRASE_PIN,
    FakeClipModel,
    FakeClipStore,
    FakePhraseModel,
    make_clip_service,
    make_service,
)
from quality.produce import (
    ClipProducer,
    PhraseProducer,
    ReplayMiss,
    ReplayProducer,
)

_GLOSS_ITEM = {"lemma": "key", "partOfSpeech": "noun", "senseHint": "a small metal object"}


@pytest.mark.asyncio
async def test_the_phrase_producer_maps_the_item_through_the_service() -> None:
    model = FakePhraseModel(["a key in the door"])
    producer = PhraseProducer(make_service(model), model_pin=PHRASE_PIN)

    outcome = await producer(_GLOSS_ITEM)

    assert outcome == {
        "phrase": "a key in the door",
        "source": "generated",
        "bestGuess": False,
        "failed": False,
        "reason": None,
    }
    _system, user, pin = model.calls[0]
    assert "key" in user
    assert "a small metal object" in user
    assert pin == PHRASE_PIN


@pytest.mark.asyncio
async def test_the_phrase_producer_captures_provider_unavailability() -> None:
    model = FakePhraseModel([ProviderUnavailable("down")])
    producer = PhraseProducer(make_service(model), model_pin=PHRASE_PIN)

    outcome = await producer(_GLOSS_ITEM)

    assert outcome["failed"] is True
    assert outcome["source"] == "fallback"
    assert outcome["reason"] is not None and "unavailable" in outcome["reason"]


@pytest.mark.asyncio
async def test_the_phrase_producer_reports_a_fallback_as_generated_false() -> None:
    model = FakePhraseModel([ProviderRefusal("declined")])
    producer = PhraseProducer(make_service(model), model_pin=PHRASE_PIN)

    outcome = await producer(_GLOSS_ITEM)

    assert outcome["source"] == "fallback"
    assert outcome["bestGuess"] is True
    assert outcome["failed"] is False


@pytest.mark.asyncio
async def test_the_clip_producer_reports_a_produced_clip() -> None:
    model = FakeClipModel([CLIP_BYTES])
    service = make_clip_service(model, store=FakeClipStore())
    producer = ClipProducer(service, model_pin=CLIP_PIN)

    outcome = await producer({"word": "key", "phrase": "a key in the door"})

    assert outcome["produced"] is True
    assert outcome["durationSeconds"] == 4.0
    assert outcome["resolution"] == "360p"
    assert outcome["hasAudio"] is True
    assert outcome["synthIdWatermark"] is True


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("failure", "reason"),
    [
        (ProviderRefusal("declined"), "declined"),
        (ProviderTimeout("slow"), "timeout"),
        (ProviderUnavailable("down"), "unavailable"),
    ],
)
async def test_the_clip_producer_captures_provider_failures(
    failure: Exception, reason: str
) -> None:
    model = FakeClipModel([failure])
    service = make_clip_service(model, store=FakeClipStore())
    producer = ClipProducer(service, model_pin=CLIP_PIN)

    outcome = await producer({"phrase": "a key in the door"})

    assert outcome["produced"] is False
    assert outcome["reason"] == reason


@pytest.mark.asyncio
async def test_the_replay_producer_feeds_back_recorded_outputs() -> None:
    recorded = {"key|noun|hint": {"phrase": "a key", "source": "generated"}}
    producer = ReplayProducer(lambda item: "key|noun|hint", recorded)

    outcome = await producer({"lemma": "key"})

    assert outcome == {"phrase": "a key", "source": "generated"}


@pytest.mark.asyncio
async def test_the_replay_producer_refuses_a_missing_output() -> None:
    producer = ReplayProducer(lambda item: "absent", {})

    with pytest.raises(ReplayMiss):
        await producer({"lemma": "key"})

"""Phrase-service orchestration: generation, regeneration, fallback (FEAT-004)."""

from __future__ import annotations

import pytest
from app.phrase.service import PhraseRequest
from app.provider import ProviderRefusal, ProviderTimeout, ProviderUnavailable
from helpers import (
    DEFAULT_HINT,
    DEFAULT_LEMMA,
    DEFAULT_POS,
    PHRASE_PIN,
    FakePhraseModel,
    make_service,
)


def request(*, lemma: str | None = DEFAULT_LEMMA, sense_hint: str = DEFAULT_HINT) -> PhraseRequest:
    return PhraseRequest(
        lemma=lemma,
        part_of_speech=DEFAULT_POS,
        sense_hint=sense_hint,
        model_pin=PHRASE_PIN,
    )


@pytest.mark.asyncio
async def test_returns_a_generated_phrase() -> None:
    model = FakePhraseModel(["a key in the door"])

    result = await make_service(model).generate(request())

    assert result.phrase == "a key in the door"
    assert result.source == "generated"
    assert result.best_guess is False
    assert model.calls[0][2] == PHRASE_PIN


@pytest.mark.asyncio
async def test_refusal_becomes_a_best_guess_fallback() -> None:
    model = FakePhraseModel([ProviderRefusal("declined")])

    result = await make_service(model).generate(request())

    assert result.phrase == "a key"
    assert result.source == "fallback"
    assert result.best_guess is True
    assert len(model.calls) == 1


@pytest.mark.asyncio
async def test_timeout_becomes_a_best_guess_fallback() -> None:
    model = FakePhraseModel([ProviderTimeout("slow")])

    result = await make_service(model).generate(request())

    assert result.source == "fallback"
    assert result.best_guess is True
    assert len(model.calls) == 1


@pytest.mark.asyncio
async def test_unusable_output_is_regenerated() -> None:
    model = FakePhraseModel(["a key in the perambulator", "a key in the door"])

    result = await make_service(model).generate(request())

    assert result.phrase == "a key in the door"
    assert result.source == "generated"
    assert len(model.calls) == 2


@pytest.mark.asyncio
async def test_repeated_unusable_output_falls_back() -> None:
    model = FakePhraseModel(["a key in the perambulator", "a key in the perambulator"])

    result = await make_service(model).generate(request())

    assert result.source == "fallback"
    assert result.best_guess is True
    assert len(model.calls) == 2


@pytest.mark.asyncio
async def test_provider_unavailable_propagates() -> None:
    model = FakePhraseModel([ProviderUnavailable("down")])

    with pytest.raises(ProviderUnavailable):
        await make_service(model).generate(request())


@pytest.mark.asyncio
async def test_accepts_a_phrase_at_the_settled_word_cap() -> None:
    model = FakePhraseModel(["she put the key in the door"])

    result = await make_service(model).generate(request())

    assert result.phrase == "she put the key in the door"
    assert result.source == "generated"


@pytest.mark.asyncio
async def test_a_phrase_over_the_settled_word_cap_falls_back() -> None:
    model = FakePhraseModel(["a key in the door on the wall"] * 2)

    result = await make_service(model).generate(request())

    assert result.source == "fallback"
    assert result.best_guess is True
    assert len(model.calls) == 2


@pytest.mark.asyncio
async def test_prompt_uses_the_sense_hint_when_lemma_is_absent() -> None:
    model = FakePhraseModel(["a key in the door"])

    await make_service(model).generate(request(lemma=None))

    _system, user, _pin = model.calls[0]
    assert DEFAULT_HINT in user


@pytest.mark.asyncio
async def test_falls_back_when_lemma_is_absent() -> None:
    model = FakePhraseModel([ProviderRefusal("declined")])

    result = await make_service(model).generate(request(lemma=None, sense_hint="ice on a lake"))

    assert result.phrase == "an ice"

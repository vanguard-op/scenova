"""Client tests for the model-serving phrase endpoint (C-004 status mapping)."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from pipeline.app.phrase_client import HttpPhraseClient, PhraseUnavailableError


def _body(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "phrase": "a key in the door",
        "source": "generated",
        "bestGuess": False,
    }
    body.update(overrides)
    return body


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpPhraseClient:
    return HttpPhraseClient(
        base_url="http://model",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_a_generated_phrase_is_mapped_from_the_contract() -> None:
    client = _client(lambda _request: httpx2.Response(200, json=_body()))

    result = await client.generate(
        lemma="key",
        part_of_speech="noun",
        sense_hint="door_opener",
        model_pin="gemini-3.5-flash-lite",
    )

    assert result.phrase == "a key in the door"
    assert result.source == "generated"
    assert result.best_guess is False
    await client.aclose()


@pytest.mark.asyncio
async def test_a_fallback_phrase_is_carried_through_as_a_result() -> None:
    # The model layer's own fallback is a normal 200, not an error: the pipeline
    # must not turn it into a failed job.
    client = _client(
        lambda _request: httpx2.Response(
            200, json=_body(phrase="an ice", source="fallback", bestGuess=True)
        )
    )

    result = await client.generate(
        lemma="ice", part_of_speech="noun", sense_hint="frozen_water", model_pin="pin"
    )

    assert result.phrase == "an ice"
    assert result.source == "fallback"
    assert result.best_guess is True
    await client.aclose()


@pytest.mark.asyncio
async def test_the_request_carries_the_audience_and_the_contract_fields() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(200, json=_body())

    client = _client(handler)
    await client.generate(
        lemma="key",
        part_of_speech="noun",
        sense_hint="door_opener",
        model_pin="gemini-3.5-flash-lite",
    )

    assert seen["path"] == "/internal/model/phrase"
    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {
        "lemma": "key",
        "partOfSpeech": "noun",
        "senseHint": "door_opener",
        "modelPin": "gemini-3.5-flash-lite",
    }
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unavailable_provider_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    with pytest.raises(PhraseUnavailableError):
        await client.generate(lemma="key", part_of_speech="noun", sense_hint="x", model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unexpected_status_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(500, json={"code": "boom"}))

    with pytest.raises(PhraseUnavailableError):
        await client.generate(lemma="key", part_of_speech="noun", sense_hint="x", model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unusable_body_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(200, json={"phrase": "a key"}))

    with pytest.raises(PhraseUnavailableError):
        await client.generate(lemma="key", part_of_speech="noun", sense_hint="x", model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_is_treated_as_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(PhraseUnavailableError):
        await client.generate(lemma="key", part_of_speech="noun", sense_hint="x", model_pin="pin")
    await client.aclose()

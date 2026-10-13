"""Client tests for the model-serving clip endpoint (C-005 status mapping)."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from pipeline.app.clip_client import (
    ClipDeclinedError,
    ClipTimeoutError,
    ClipUnavailableError,
    HttpClipClient,
)


def _body(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "clipId": "clip-1",
        "storageKey": "clips/clip-1.mp4",
        "url": "https://cdn.example/clip-1.mp4",
        "durationSeconds": 3.0,
        "resolution": "360p",
        "hasAudio": False,
        "synthIdWatermark": True,
    }
    body.update(overrides)
    return body


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpClipClient:
    return HttpClipClient(
        base_url="http://model",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_a_produced_clip_is_mapped_from_the_contract() -> None:
    client = _client(lambda _request: httpx2.Response(201, json=_body()))

    result = await client.generate(
        phrase="a key in the door", target_duration_seconds=3.0, model_pin="gemini-omni-1.1-flash"
    )

    assert result.clip_id == "clip-1"
    assert result.storage_key == "clips/clip-1.mp4"
    assert result.duration_seconds == 3.0
    assert result.resolution == "360p"
    assert result.has_audio is False
    assert result.synth_id_watermark is True
    await client.aclose()


@pytest.mark.asyncio
async def test_the_request_carries_the_audience_and_the_contract_fields() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(201, json=_body())

    client = _client(handler)
    await client.generate(
        phrase="a key in the door", target_duration_seconds=4.0, model_pin="gemini-omni-1.1-flash"
    )

    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {
        "phrase": "a key in the door",
        "targetDurationSeconds": 4.0,
        "modelPin": "gemini-omni-1.1-flash",
    }
    await client.aclose()


@pytest.mark.asyncio
async def test_a_declined_phrase_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(422, json={"code": "declined"}))

    with pytest.raises(ClipDeclinedError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_a_provider_timeout_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(504, json={"code": "timeout"}))

    with pytest.raises(ClipTimeoutError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unavailable_provider_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    with pytest.raises(ClipUnavailableError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unexpected_status_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(500, json={"code": "boom"}))

    with pytest.raises(ClipUnavailableError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unusable_body_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(201, json={"clipId": "clip-1"}))

    with pytest.raises(ClipUnavailableError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_is_treated_as_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(ClipUnavailableError):
        await client.generate(phrase="x", target_duration_seconds=3.0, model_pin="pin")
    await client.aclose()

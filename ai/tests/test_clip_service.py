"""Clip-service orchestration: duration, storage, refusal mapping (FEAT-005)."""

from __future__ import annotations

import pytest
from app.clip.service import ClipRequest
from app.clip.store import ClipStorageError
from app.provider import ProviderRefusal, ProviderTimeout, ProviderUnavailable
from helpers import (
    CLIP_BYTES,
    CLIP_PIN,
    DEFAULT_PHRASE,
    FakeClipModel,
    FakeClipStore,
    make_clip_service,
)


def request(*, phrase: str = DEFAULT_PHRASE, duration: float = 4.0) -> ClipRequest:
    return ClipRequest(phrase=phrase, target_duration_seconds=duration, model_pin=CLIP_PIN)


@pytest.mark.asyncio
async def test_generates_and_stores_a_clip() -> None:
    model = FakeClipModel([CLIP_BYTES])
    store = FakeClipStore()

    result = await make_clip_service(model, store=store).generate(request())

    assert result.duration_seconds == 4.0
    assert result.resolution == "360p"
    assert result.has_audio is False
    assert result.synth_id_watermark is True
    assert result.storage_key == f"clips/{result.clip_id}.mp4"
    assert store.puts == [(result.storage_key, CLIP_BYTES, "video/mp4")]


@pytest.mark.asyncio
async def test_prompt_and_pins_are_passed_to_the_provider() -> None:
    model = FakeClipModel([CLIP_BYTES])

    await make_clip_service(model).generate(request(phrase="a spoon on a table"))

    call = model.calls[0]
    assert "a spoon on a table" in call["user"]
    assert call["model_pin"] == CLIP_PIN
    assert call["resolution"] == "360p"
    assert call["generate_audio"] is False


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("target", "expected"),
    [(1.0, 1), (2.5, 3), (4.0, 4), (0.2, 1), (9.0, 4)],
)
async def test_duration_is_clamped_to_the_output_contract(target: float, expected: int) -> None:
    model = FakeClipModel([CLIP_BYTES])

    result = await make_clip_service(model).generate(request(duration=target))

    assert model.calls[0]["duration_seconds"] == expected
    assert result.duration_seconds == float(expected)


@pytest.mark.asyncio
async def test_each_clip_gets_its_own_key() -> None:
    model = FakeClipModel([CLIP_BYTES, CLIP_BYTES])
    service = make_clip_service(model)

    first = await service.generate(request())
    second = await service.generate(request())

    assert first.clip_id != second.clip_id
    assert first.storage_key != second.storage_key


@pytest.mark.asyncio
async def test_refusal_propagates_without_storing() -> None:
    store = FakeClipStore()

    with pytest.raises(ProviderRefusal):
        await make_clip_service(FakeClipModel([ProviderRefusal("declined")]), store=store).generate(
            request()
        )

    assert store.puts == []


@pytest.mark.asyncio
async def test_timeout_propagates() -> None:
    with pytest.raises(ProviderTimeout):
        await make_clip_service(FakeClipModel([ProviderTimeout("slow")])).generate(request())


@pytest.mark.asyncio
async def test_unavailable_propagates() -> None:
    with pytest.raises(ProviderUnavailable):
        await make_clip_service(FakeClipModel([ProviderUnavailable("down")])).generate(request())


@pytest.mark.asyncio
async def test_storage_failure_propagates() -> None:
    store = FakeClipStore(fail=True)

    with pytest.raises(ClipStorageError):
        await make_clip_service(FakeClipModel([CLIP_BYTES]), store=store).generate(request())

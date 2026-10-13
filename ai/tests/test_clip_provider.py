"""Clip-provider wrapper: retries, circuit breaker, failure mapping (C-005)."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import httpx
import pytest
from app.config import Settings
from app.provider import (
    GeminiClipModel,
    ProviderRefusal,
    ProviderTimeout,
    ProviderUnavailable,
    _combine_prompt,
    _extract_video,
)
from helpers import CLIP_BYTES, CLIP_PIN, make_test_settings


class _ScriptedClipModel(GeminiClipModel):
    """A GeminiClipModel whose transport result is scripted per attempt."""

    def __init__(self, settings: Settings, results: list[bytes | Exception]) -> None:
        super().__init__(settings)
        self._scripted = list(results)
        self.calls = 0

    async def _call(
        self,
        *,
        system: str,
        user: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> bytes:
        self.calls += 1
        result = self._scripted.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


async def _generate(model: GeminiClipModel) -> bytes:
    return await model.generate(
        system="s",
        user="u",
        model_pin=CLIP_PIN,
        duration_seconds=4,
        resolution="360p",
        generate_audio=False,
    )


def _stub_video_client(generate_videos: Any) -> Any:
    models = SimpleNamespace(generate_videos=generate_videos)
    return SimpleNamespace(aio=SimpleNamespace(models=models))


@pytest.mark.asyncio
async def test_retries_a_transient_failure_then_succeeds() -> None:
    model = _ScriptedClipModel(
        make_test_settings(max_attempts=2),
        [ProviderUnavailable("boom"), CLIP_BYTES],
    )

    data = await _generate(model)

    assert data == CLIP_BYTES
    assert model.calls == 2


@pytest.mark.asyncio
async def test_exhausted_retries_raise_unavailable_and_open_the_circuit() -> None:
    model = _ScriptedClipModel(
        make_test_settings(max_attempts=2, circuit_failure_threshold=1),
        [ProviderUnavailable("boom"), ProviderUnavailable("boom")],
    )

    with pytest.raises(ProviderUnavailable):
        await _generate(model)
    assert model.calls == 2

    with pytest.raises(ProviderUnavailable):
        await _generate(model)
    assert model.calls == 2  # the open circuit stopped the second call


@pytest.mark.asyncio
async def test_timeout_is_not_retried() -> None:
    model = _ScriptedClipModel(make_test_settings(max_attempts=3), [ProviderTimeout("slow")])

    with pytest.raises(ProviderTimeout):
        await _generate(model)

    assert model.calls == 1


@pytest.mark.asyncio
async def test_refusal_is_not_retried() -> None:
    model = _ScriptedClipModel(make_test_settings(max_attempts=3), [ProviderRefusal("declined")])

    with pytest.raises(ProviderRefusal):
        await _generate(model)

    assert model.calls == 1


@pytest.mark.asyncio
async def test_elapsed_timeout_maps_to_provider_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings())

    async def _generate_videos(**_kwargs: Any) -> Any:
        raise TimeoutError

    monkeypatch.setattr(model, "_get_client", lambda: _stub_video_client(_generate_videos))

    with pytest.raises(ProviderTimeout):
        await _generate(model)


@pytest.mark.asyncio
async def test_network_error_maps_to_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings(max_attempts=1))

    async def _generate_videos(**_kwargs: Any) -> Any:
        raise httpx.ConnectError("no route to host")

    monkeypatch.setattr(model, "_get_client", lambda: _stub_video_client(_generate_videos))

    with pytest.raises(ProviderUnavailable):
        await _generate(model)


@pytest.mark.asyncio
async def test_missing_credentials_are_unavailable() -> None:
    model = GeminiClipModel(make_test_settings(gemini_api_key=None, max_attempts=1))

    with pytest.raises(ProviderUnavailable):
        await _generate(model)


def test_combine_prompt_keeps_both_parts() -> None:
    combined = _combine_prompt(system="direct it", user="Phrase: a key")

    assert "direct it" in combined
    assert "Phrase: a key" in combined


def _operation(*, error: Any = None, videos: list[Any] | None = None, filtered: int = 0) -> Any:
    response = SimpleNamespace(generated_videos=videos, rai_media_filtered_count=filtered)
    return SimpleNamespace(error=error, response=response)


def test_extract_video_returns_the_bytes() -> None:
    video = SimpleNamespace(video=SimpleNamespace(video_bytes=b"clip"))
    operation = _operation(videos=[video])

    assert _extract_video(operation) == b"clip"


def test_extract_video_treats_an_empty_result_as_a_refusal() -> None:
    with pytest.raises(ProviderRefusal):
        _extract_video(_operation(videos=[]))


def test_extract_video_treats_a_filtered_result_as_a_refusal() -> None:
    with pytest.raises(ProviderRefusal):
        _extract_video(_operation(videos=[], filtered=1))


def test_extract_video_treats_an_operation_error_as_unavailable() -> None:
    with pytest.raises(ProviderUnavailable):
        _extract_video(_operation(error={"code": 500}))


def test_extract_video_treats_missing_bytes_as_a_refusal() -> None:
    video = SimpleNamespace(video=SimpleNamespace(video_bytes=None))

    with pytest.raises(ProviderRefusal):
        _extract_video(_operation(videos=[video]))

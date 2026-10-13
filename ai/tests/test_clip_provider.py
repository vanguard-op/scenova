"""Clip-provider wrapper: the Interactions API, retries, failure mapping (C-005).

The pinned clip model (Gemini Omni Flash) is served by the Interactions API, so
these guard that the wrapper calls `interactions.create` with the output contract
(resolution, duration), reads the clip from the interaction, and maps every
outcome onto C-005.
"""

from __future__ import annotations

import base64
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
    _inline_video_bytes,
    _interaction_video,
)
from google.genai import errors as genai_errors
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
    )


def _stub_client(*, create: Any, get: Any = None, download: Any = None) -> Any:
    interactions = SimpleNamespace(create=create, get=get)
    files = SimpleNamespace(download=download)
    aio = SimpleNamespace(interactions=interactions, files=files)
    return SimpleNamespace(aio=aio)


def _interaction(
    *,
    id: str = "abc",
    status: str = "completed",
    video: Any = None,
    errors: Any = None,
) -> Any:
    return SimpleNamespace(id=id, status=status, output_video=video, errors=errors)


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
async def test_missing_credentials_are_unavailable() -> None:
    model = GeminiClipModel(make_test_settings(gemini_api_key=None, max_attempts=1))

    with pytest.raises(ProviderUnavailable):
        await _generate(model)


def test_combine_prompt_keeps_both_parts() -> None:
    combined = _combine_prompt(system="direct it", user="Phrase: a key")

    assert "direct it" in combined
    assert "Phrase: a key" in combined


@pytest.mark.asyncio
async def test_calls_the_interactions_api_with_the_output_contract(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    model = GeminiClipModel(make_test_settings())
    calls: list[dict[str, Any]] = []

    async def _create(**kwargs: Any) -> Any:
        calls.append(kwargs)
        return _interaction(video=SimpleNamespace(data=base64.b64encode(CLIP_BYTES).decode()))

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create))

    data = await _generate(model)

    assert data == CLIP_BYTES
    # The pinned Omni model is served by the Interactions API, not generate_videos.
    assert calls[0]["model"] == CLIP_PIN
    assert calls[0]["input"] == "s\n\nu"
    assert calls[0]["response_format"] == {
        "type": "video",
        "resolution": "360p",
        "duration": "4s",
    }


@pytest.mark.asyncio
async def test_polls_an_in_flight_interaction_to_completion(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    model = GeminiClipModel(make_test_settings(clip_poll_interval_seconds=0.0))
    polled: list[str] = []

    async def _create(**_kwargs: Any) -> Any:
        return _interaction(status="in_progress")

    async def _get(interaction_id: str) -> Any:
        polled.append(interaction_id)
        return _interaction(
            status="completed",
            video=SimpleNamespace(data=base64.b64encode(CLIP_BYTES).decode()),
        )

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create, get=_get))

    data = await _generate(model)

    assert data == CLIP_BYTES
    assert polled == ["abc"]


@pytest.mark.asyncio
async def test_uri_delivery_is_downloaded(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings())
    downloaded: list[str] = []
    file_uri = "https://generativelanguage.googleapis.com/v1beta/files/xyz:download"

    async def _create(**_kwargs: Any) -> Any:
        return _interaction(video=SimpleNamespace(data=None, uri=file_uri))

    async def _download(*, file: str) -> bytes:
        downloaded.append(file)
        return CLIP_BYTES

    monkeypatch.setattr(
        model,
        "_get_client",
        lambda: _stub_client(create=_create, download=_download),
    )

    data = await _generate(model)

    assert data == CLIP_BYTES
    assert downloaded == [file_uri]


@pytest.mark.asyncio
async def test_elapsed_timeout_maps_to_provider_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    model = GeminiClipModel(make_test_settings())

    async def _create(**_kwargs: Any) -> Any:
        raise TimeoutError

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create))

    with pytest.raises(ProviderTimeout):
        await _generate(model)


@pytest.mark.asyncio
async def test_network_error_maps_to_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings(max_attempts=1))

    async def _create(**_kwargs: Any) -> Any:
        raise httpx.ConnectError("no route to host")

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create))

    with pytest.raises(ProviderUnavailable):
        await _generate(model)


@pytest.mark.asyncio
async def test_a_rejected_input_maps_to_a_refusal(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings(max_attempts=1))

    async def _create(**_kwargs: Any) -> Any:
        raise genai_errors.APIError(
            400,
            {"error": {"code": 400, "status": "INVALID_ARGUMENT", "message": "blocked"}},
        )

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create))

    with pytest.raises(ProviderRefusal):
        await _generate(model)


@pytest.mark.asyncio
async def test_a_server_error_maps_to_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiClipModel(make_test_settings(max_attempts=1))

    async def _create(**_kwargs: Any) -> Any:
        raise genai_errors.APIError(500, {"error": {"code": 500, "status": "INTERNAL"}})

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(create=_create))

    with pytest.raises(ProviderUnavailable):
        await _generate(model)


def test_interaction_video_returns_the_video_block() -> None:
    video = SimpleNamespace(data="AAAA")

    assert _interaction_video(_interaction(video=video)) is video


def test_interaction_video_treats_a_completed_but_empty_result_as_a_refusal() -> None:
    with pytest.raises(ProviderRefusal):
        _interaction_video(_interaction(status="completed", video=None))


def test_interaction_video_treats_a_platform_fault_as_unavailable() -> None:
    with pytest.raises(ProviderUnavailable):
        _interaction_video(_interaction(status="failed", video=None, errors=["boom"]))


def test_inline_video_bytes_decodes_base64() -> None:
    video = SimpleNamespace(data=base64.b64encode(b"clip").decode())

    assert _inline_video_bytes(video) == b"clip"


def test_inline_video_bytes_is_none_for_a_uri_delivery() -> None:
    assert _inline_video_bytes(SimpleNamespace(data=None, uri="files/x:download")) is None

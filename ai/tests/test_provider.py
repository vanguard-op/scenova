"""Provider wrapper: retries, circuit breaker, failure mapping (C-004)."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import httpx
import pytest
from app.config import Settings
from app.provider import (
    GeminiPhraseModel,
    ProviderRefusal,
    ProviderTimeout,
    ProviderUnavailable,
)
from helpers import DEFAULT_PIN, make_test_settings


class _ScriptedModel(GeminiPhraseModel):
    """A GeminiPhraseModel whose transport result is scripted per attempt."""

    def __init__(self, settings: Settings, results: list[str | Exception]) -> None:
        super().__init__(settings)
        self._scripted = list(results)
        self.calls = 0

    async def _call(self, *, system: str, user: str, model_pin: str) -> str:
        self.calls += 1
        result = self._scripted.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def _stub_client(generate_content: Any) -> Any:
    models = SimpleNamespace(generate_content=generate_content)
    return SimpleNamespace(aio=SimpleNamespace(models=models))


@pytest.mark.asyncio
async def test_retries_a_transient_failure_then_succeeds() -> None:
    model = _ScriptedModel(
        make_test_settings(max_attempts=2),
        [ProviderUnavailable("boom"), "a key in the door"],
    )

    text = await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)

    assert text == "a key in the door"
    assert model.calls == 2


@pytest.mark.asyncio
async def test_exhausted_retries_raise_unavailable_and_open_the_circuit() -> None:
    model = _ScriptedModel(
        make_test_settings(max_attempts=2, circuit_failure_threshold=1),
        [ProviderUnavailable("boom"), ProviderUnavailable("boom")],
    )

    with pytest.raises(ProviderUnavailable):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)
    assert model.calls == 2

    with pytest.raises(ProviderUnavailable):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)
    assert model.calls == 2  # the open circuit stopped the second call


@pytest.mark.asyncio
async def test_timeout_is_not_retried() -> None:
    model = _ScriptedModel(
        make_test_settings(max_attempts=3),
        [ProviderTimeout("slow")],
    )

    with pytest.raises(ProviderTimeout):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)

    assert model.calls == 1


@pytest.mark.asyncio
async def test_empty_response_is_a_refusal(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiPhraseModel(make_test_settings())

    async def _generate_content(**_kwargs: Any) -> Any:
        return SimpleNamespace(text=None)

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(_generate_content))

    with pytest.raises(ProviderRefusal):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)


@pytest.mark.asyncio
async def test_elapsed_timeout_maps_to_provider_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiPhraseModel(make_test_settings())

    async def _generate_content(**_kwargs: Any) -> Any:
        raise TimeoutError

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(_generate_content))

    with pytest.raises(ProviderTimeout):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)


@pytest.mark.asyncio
async def test_network_error_maps_to_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    model = GeminiPhraseModel(make_test_settings(max_attempts=1))

    async def _generate_content(**_kwargs: Any) -> Any:
        raise httpx.ConnectError("no route to host")

    monkeypatch.setattr(model, "_get_client", lambda: _stub_client(_generate_content))

    with pytest.raises(ProviderUnavailable):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)


@pytest.mark.asyncio
async def test_missing_credentials_are_unavailable() -> None:
    model = GeminiPhraseModel(make_test_settings(gemini_api_key=None, max_attempts=1))

    with pytest.raises(ProviderUnavailable):
        await model.generate(system="s", user="u", model_pin=DEFAULT_PIN)

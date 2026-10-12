"""Shared fakes and builders for the model-serving tests.

The provider is faked everywhere so the suite is deterministic and offline; the
golden-set evaluation against the live model is QA's layer, not this one.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from app.config import Settings, get_settings, load_settings
from app.data import load_common_words
from app.dependencies import get_phrase_service
from app.main import create_app
from app.phrase.service import PhraseService
from app.prompt import load_prompt
from fastapi import FastAPI

INTERNAL_AUDIENCE = "scenova-internal"
AUTH_HEADERS = {"x-internal-audience": INTERNAL_AUDIENCE}
DEFAULT_LEMMA = "key"
DEFAULT_POS = "noun"
DEFAULT_HINT = "a small metal object that opens a lock"
DEFAULT_PIN = "gemini-omni-1.1-flash"


class FakePhraseModel:
    """A deterministic stand-in for the provider: a script of strings/exceptions."""

    def __init__(self, results: list[str | Exception]) -> None:
        self._results = list(results)
        self.calls: list[tuple[str, str, str]] = []

    async def generate(self, *, system: str, user: str, model_pin: str) -> str:
        self.calls.append((system, user, model_pin))
        if not self._results:
            raise AssertionError("FakePhraseModel ran out of scripted results")
        result = self._results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def make_test_settings(**overrides: Any) -> Settings:
    """Settings pinned for tests: no network, no backoff, a fixed audience."""

    base = replace(
        load_settings(),
        gemini_api_key=None,
        internal_audience=INTERNAL_AUDIENCE,
        retry_backoff_seconds=0.0,
        max_attempts=3,
        regeneration_attempts=2,
        circuit_failure_threshold=2,
        circuit_reset_seconds=60.0,
    )
    return replace(base, **overrides)


def make_service(
    model: Any,
    *,
    settings: Settings | None = None,
    common_words: frozenset[str] | None = None,
) -> PhraseService:
    return PhraseService(
        model=model,
        prompt=load_prompt(),
        common_words=common_words or load_common_words(),
        settings=settings or make_test_settings(),
    )


def make_app(
    model: Any,
    *,
    settings: Settings | None = None,
    common_words: frozenset[str] | None = None,
) -> FastAPI:
    """Build the real app with the provider and settings injected."""

    resolved = settings or make_test_settings()
    service = make_service(model, settings=resolved, common_words=common_words)
    app = create_app()
    app.dependency_overrides[get_phrase_service] = lambda: service
    app.dependency_overrides[get_settings] = lambda: resolved
    return app


def phrase_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "lemma": DEFAULT_LEMMA,
        "partOfSpeech": DEFAULT_POS,
        "senseHint": DEFAULT_HINT,
        "modelPin": DEFAULT_PIN,
    }
    payload.update(overrides)
    return payload

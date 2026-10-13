"""Shared fakes and builders for the model-serving tests.

The provider is faked everywhere so the suite is deterministic and offline; the
golden-set evaluation against the live model is QA's layer, not this one.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from app.clip.service import ClipService
from app.clip.store import ClipStorageError, StoredClip, clip_url
from app.config import Settings, get_settings, load_settings
from app.data import load_common_words
from app.dependencies import get_clip_service, get_phrase_service
from app.main import create_app
from app.phrase.service import PhraseService
from app.prompt import DEFAULT_CLIP_PROMPT_PATH, load_prompt
from fastapi import FastAPI

INTERNAL_AUDIENCE = "scenova-internal"
AUTH_HEADERS = {"x-internal-audience": INTERNAL_AUDIENCE}
DEFAULT_LEMMA = "key"
DEFAULT_POS = "noun"
DEFAULT_HINT = "a small metal object that opens a lock"
DEFAULT_PHRASE = "a key in the door"
PHRASE_PIN = "gemini-3.5-flash-lite"
CLIP_PIN = "gemini-omni-1.1-flash"
CDN_BASE = "https://cdn.test"
CLIP_RESOLUTION = "360p"
CLIP_BYTES = b"\x00\x00\x00\x18ftypmp42scenova-test-clip"


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
        clip_bucket="scenova-clips-test",
        clip_cdn_base_url=CDN_BASE,
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
    clip_model: Any = None,
    clip_store: Any = None,
) -> FastAPI:
    """Build the real app with the provider and settings injected."""

    resolved = settings or make_test_settings()
    service = make_service(model, settings=resolved, common_words=common_words)
    app = create_app()
    app.dependency_overrides[get_phrase_service] = lambda: service
    app.dependency_overrides[get_settings] = lambda: resolved
    if clip_model is not None:
        clip_service = make_clip_service(clip_model, store=clip_store, settings=resolved)
        app.dependency_overrides[get_clip_service] = lambda: clip_service
    return app


def phrase_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "lemma": DEFAULT_LEMMA,
        "partOfSpeech": DEFAULT_POS,
        "senseHint": DEFAULT_HINT,
        "modelPin": PHRASE_PIN,
    }
    payload.update(overrides)
    return payload


class FakeClipModel:
    """A deterministic stand-in for the video provider: a script of bytes/exceptions."""

    def __init__(self, results: list[bytes | Exception]) -> None:
        self._results = list(results)
        self.calls: list[dict[str, Any]] = []

    async def generate(
        self,
        *,
        system: str,
        user: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> bytes:
        self.calls.append(
            {
                "system": system,
                "user": user,
                "model_pin": model_pin,
                "duration_seconds": duration_seconds,
                "resolution": resolution,
                "generate_audio": generate_audio,
            }
        )
        if not self._results:
            raise AssertionError("FakeClipModel ran out of scripted results")
        result = self._results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class FakeClipStore:
    """An in-memory clip store that records writes and can be made to fail."""

    def __init__(self, *, settings: Settings | None = None, fail: bool = False) -> None:
        self._settings = settings or make_test_settings()
        self._fail = fail
        self.puts: list[tuple[str, bytes, str]] = []

    async def put(self, *, storage_key: str, data: bytes, content_type: str) -> StoredClip:
        if self._fail:
            raise ClipStorageError("clip store unavailable")
        self.puts.append((storage_key, data, content_type))
        return StoredClip(
            storage_key=storage_key,
            url=clip_url(storage_key=storage_key, settings=self._settings),
        )


def make_clip_service(
    model: Any,
    *,
    store: Any = None,
    settings: Settings | None = None,
    prompt: Any = None,
) -> ClipService:
    resolved = settings or make_test_settings()
    return ClipService(
        model=model,
        store=store or FakeClipStore(settings=resolved),
        prompt=prompt or load_prompt(DEFAULT_CLIP_PROMPT_PATH),
        settings=resolved,
    )


def clip_payload(**overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "phrase": DEFAULT_PHRASE,
        "targetDurationSeconds": 4,
        "modelPin": CLIP_PIN,
    }
    payload.update(overrides)
    return payload

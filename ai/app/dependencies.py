"""Wiring for the model-serving endpoints.

The phrase and clip services are built once per process (the provider client and
the bundled vocabulary are reused) and are overridable in tests.
"""

from __future__ import annotations

from functools import lru_cache

from .clip.service import ClipService
from .clip.store import GcsClipStore
from .config import get_settings
from .data import load_common_words
from .phrase.service import PhraseService
from .prompt import DEFAULT_CLIP_PROMPT_PATH, load_prompt
from .provider import ClipModel, GeminiClipModel, GeminiPhraseModel, PhraseModel


@lru_cache(maxsize=1)
def _build_phrase_service() -> PhraseService:
    settings = get_settings()
    model: PhraseModel = GeminiPhraseModel(settings)
    return PhraseService(
        model=model,
        prompt=load_prompt(),
        common_words=load_common_words(),
        settings=settings,
    )


def get_phrase_service() -> PhraseService:
    return _build_phrase_service()


@lru_cache(maxsize=1)
def _build_clip_service() -> ClipService:
    settings = get_settings()
    model: ClipModel = GeminiClipModel(settings)
    return ClipService(
        model=model,
        store=GcsClipStore(settings),
        prompt=load_prompt(DEFAULT_CLIP_PROMPT_PATH),
        settings=settings,
    )


def get_clip_service() -> ClipService:
    return _build_clip_service()

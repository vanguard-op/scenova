"""Wiring for the model-serving endpoints.

The phrase service is built once per process (the provider client and the
bundled vocabulary are reused) and is overridable in tests.
"""

from __future__ import annotations

from functools import lru_cache

from .config import get_settings
from .data import load_common_words
from .phrase.service import PhraseService
from .prompt import load_prompt
from .provider import GeminiPhraseModel, PhraseModel


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

"""Gloss-phrase generation service (FEAT-004).

Orchestrates one model-backed phrase: render the versioned prompt, call the
provider, check the output against the guardrails, regenerate once if the
output is unusable, and otherwise substitute the fallback. Provider
unavailability is the only failure that leaves this layer, so the pipeline can
map it to HTTP 503.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Literal

from ..config import Settings
from ..prompt import PromptTemplate
from ..provider import PhraseModel, ProviderRefusal, ProviderTimeout
from .fallback import fallback_phrase
from .guardrails import is_usable

logger = logging.getLogger(__name__)

PhraseSource = Literal["generated", "fallback"]


@dataclass(frozen=True, slots=True)
class PhraseRequest:
    """A request to gloss one word or sense (C-004 input)."""

    lemma: str | None
    part_of_speech: str
    sense_hint: str
    model_pin: str


@dataclass(frozen=True, slots=True)
class PhraseResult:
    """The phrase and how it was produced (C-004 output)."""

    phrase: str
    source: PhraseSource
    best_guess: bool


class PhraseService:
    """Turns a word or sense into a short, concrete gloss phrase."""

    def __init__(
        self,
        *,
        model: PhraseModel,
        prompt: PromptTemplate,
        common_words: frozenset[str],
        settings: Settings,
    ) -> None:
        self._model = model
        self._prompt = prompt
        self._common_words = common_words
        self._settings = settings

    def _fallback(self, request: PhraseRequest) -> PhraseResult:
        return PhraseResult(
            phrase=fallback_phrase(lemma=request.lemma, sense_hint=request.sense_hint),
            source="fallback",
            best_guess=True,
        )

    async def generate(self, request: PhraseRequest) -> PhraseResult:
        system, user = self._prompt.render(
            lemma=request.lemma or request.sense_hint,
            part_of_speech=request.part_of_speech,
            sense_hint=request.sense_hint,
        )
        model_pin = request.model_pin or self._settings.model_pin
        attempts = max(1, self._settings.regeneration_attempts)

        for _ in range(attempts):
            try:
                text = await self._model.generate(
                    system=system,
                    user=user,
                    model_pin=model_pin,
                )
            except (ProviderRefusal, ProviderTimeout):
                # A declined or slow provider will not improve on a retry.
                return self._fallback(request)

            check = is_usable(
                text,
                lemma=request.lemma,
                common_words=self._common_words,
                max_words=self._settings.max_phrase_words,
                max_chars=self._settings.max_phrase_chars,
            )
            if check.ok:
                return PhraseResult(phrase=check.phrase, source="generated", best_guess=False)
            logger.info("rejected gloss phrase: %s", check.reason)

        return self._fallback(request)

"""POST /internal/model/phrase — gloss phrase generation (C-004, FEAT-004)."""

from __future__ import annotations

from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from ..auth import require_internal_caller
from ..dependencies import get_phrase_service
from ..errors import ProviderUnavailableError
from ..phrase.service import PhraseRequest, PhraseService
from ..provider import ProviderUnavailable

router = APIRouter(tags=["model"])


class PhraseRequestBody(BaseModel):
    """C-004 request: the word or sense to gloss, with its part of speech."""

    model_config = ConfigDict(extra="forbid")

    lemma: str | None = None
    partOfSpeech: str = Field(min_length=1)
    senseHint: str = Field(min_length=1)
    modelPin: str = Field(min_length=1)


class PhraseResponseBody(BaseModel):
    """C-004 response: the phrase and how it was produced."""

    phrase: str
    source: Literal["generated", "fallback"]
    bestGuess: bool


@router.post("/internal/model/phrase", response_model=PhraseResponseBody)
async def generate_phrase(
    body: PhraseRequestBody,
    service: Annotated[PhraseService, Depends(get_phrase_service)],
    _caller: Annotated[None, Depends(require_internal_caller)],
) -> PhraseResponseBody:
    try:
        result = await service.generate(
            PhraseRequest(
                lemma=body.lemma,
                part_of_speech=body.partOfSpeech,
                sense_hint=body.senseHint,
                model_pin=body.modelPin,
            )
        )
    except ProviderUnavailable as exc:
        # The caller substitutes its own fallback; this is not an error to the reader.
        raise ProviderUnavailableError("The model provider is unavailable.") from exc

    return PhraseResponseBody(
        phrase=result.phrase,
        source=result.source,
        bestGuess=result.best_guess,
    )

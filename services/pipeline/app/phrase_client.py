"""Client for the model-serving phrase endpoint (C-004, FEAT-004).

A word job reaches the pipeline without a phrase, so the pipeline asks the model
layer for a short, concrete gloss phrase from the word, its part of speech, and a
sense hint. The model layer owns the output contract and its own fallback: a
refusal, a timeout, or an unusable phrase comes back as a normal result with
`source=fallback`, so the pipeline carries whichever phrase it is given straight
to the clip step.

Unavailability after the model layer's retries is the one failure that leaves
this client (503). C-004 leaves the substitution to the caller, so the service
substitutes its own fallback phrase rather than dropping the reader to a lookup
with no phrase.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol

import httpx2
from pydantic import BaseModel, ConfigDict

from .service_identity import ServiceIdentity


@dataclass(frozen=True)
class PhraseResult:
    """A gloss phrase as returned by C-004."""

    phrase: str
    source: Literal["generated", "fallback"]
    best_guess: bool


class PhraseUnavailableError(Exception):
    """The model service or the model provider was unavailable (C-004 503)."""


class PhraseGenerator(Protocol):
    """Port for the model-serving phrase endpoint."""

    async def generate(
        self,
        *,
        lemma: str | None,
        part_of_speech: str,
        sense_hint: str,
        model_pin: str,
    ) -> PhraseResult: ...

    async def aclose(self) -> None: ...


class PhraseResponseBody(BaseModel):
    """The C-004 200 response body."""

    model_config = ConfigDict(extra="forbid")

    phrase: str
    source: Literal["generated", "fallback"]
    bestGuess: bool


class HttpPhraseClient:
    """Calls the model-serving phrase endpoint over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 40.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The model-serving layer is internal only, so Cloud Run checks the
        # caller's identity at the platform edge (nfr.md NFR-020). The audience
        # is this client's own base URL: Cloud Run binds the ID token to the
        # service being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def generate(
        self,
        *,
        lemma: str | None,
        part_of_speech: str,
        sense_hint: str,
        model_pin: str,
    ) -> PhraseResult:
        try:
            response = await self._client.post(
                "/internal/model/phrase",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                json={
                    "lemma": lemma,
                    "partOfSpeech": part_of_speech,
                    "senseHint": sense_hint,
                    "modelPin": model_pin,
                },
            )
        except httpx2.HTTPError as exc:
            raise PhraseUnavailableError("The model service is unavailable.") from exc

        if response.status_code != 200:
            raise PhraseUnavailableError("The model service returned no phrase.")

        try:
            body = PhraseResponseBody.model_validate(response.json())
        except ValueError as exc:
            raise PhraseUnavailableError("The model service returned an unusable phrase.") from exc
        return PhraseResult(phrase=body.phrase, source=body.source, best_guess=body.bestGuess)

    async def aclose(self) -> None:
        await self._client.aclose()

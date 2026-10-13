"""Wire models for the lookup service.

The response models are the C-001 / C-002 response bodies exactly; the lookup
service is the single place that builds them, and the gateway passes them
through unchanged.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict


class Kind(StrEnum):
    """Whether a selection was a single word or a short phrase."""

    WORD = "word"
    PHRASE = "phrase"


class LookupStatus(StrEnum):
    """How a lookup resolved."""

    SERVED = "served"
    GENERATING = "generating"
    FALLBACK = "fallback"
    DENIED = "denied"
    EMPTY = "empty"


class PartOfSpeech(StrEnum):
    """Part of speech for a sense, matching the LibraryEntry schema."""

    NOUN = "noun"
    VERB = "verb"
    ADJECTIVE = "adjective"
    ADVERB = "adverb"
    PREPOSITION = "preposition"
    OTHER = "other"


class Clip(BaseModel):
    """A clip attached to a sense."""

    model_config = ConfigDict(extra="forbid")

    url: str
    durationSeconds: float
    resolution: Literal["360p"] = "360p"
    hasAudio: bool


class Sense(BaseModel):
    """One sense of a word, with its clip when the library serves one."""

    model_config = ConfigDict(extra="forbid")

    senseLabel: str
    partOfSpeech: PartOfSpeech
    glossPhrase: str
    entryId: str | None
    clip: Clip | None


class LookupResponse(BaseModel):
    """The C-001 / C-002 response body."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    kind: Kind
    rawSelection: str
    normalisedLemma: str | None
    status: LookupStatus
    senses: list[Sense]
    notice: str | None
    correlationId: str


class CreateLookupRequest(BaseModel):
    """The internal create-lookup request.

    Mirrors the C-001 request fields and adds the `subject` the gateway resolved
    from the caller's token, so ownership and idempotency are scoped per caller.
    """

    model_config = ConfigDict(extra="forbid")

    selection: str
    clientLookupId: str
    platform: Literal["android", "ios"]
    locale: str
    consentModelProcessing: bool
    subject: str

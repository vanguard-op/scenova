"""Wire models for the lookup service.

The response models are the C-001 / C-002 response bodies exactly; the lookup
service is the single place that builds them, and the gateway passes them
through unchanged. C-001 carries the reader's allowance and C-002 does not, so
the create body is its own model rather than a shared one with a stray field.
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


class Allowance(BaseModel):
    """The reader's monthly lookup allowance (C-001 `allowance`).

    `used` and `limit` are the meter's reading after this lookup spent its unit;
    when the allowance was already spent the lookup resolves to the fallback and
    `used` equals `limit`, which is the signal the client reads to offer a way
    to add more. `periodEnd` is when the allowance resets.
    """

    model_config = ConfigDict(extra="forbid")

    used: int
    limit: int
    periodEnd: str


class LookupResponse(BaseModel):
    """The C-002 response body: a lookup read by id, with no allowance."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    kind: Kind
    rawSelection: str
    normalisedLemma: str | None
    status: LookupStatus
    senses: list[Sense]
    notice: str | None
    correlationId: str


class CreateLookupResponse(LookupResponse):
    """The C-001 response body: the lookup plus the reader's allowance.

    `allowance` is null for a reader who is not signed in, whose allowance is
    kept on the device and never metered here.
    """

    allowance: Allowance | None


class CreateLookupRequest(BaseModel):
    """The internal create-lookup request.

    Mirrors the C-001 request fields and adds the `subject` and the
    `isAnonymous` flag the gateway resolved from the caller's token, so
    ownership and idempotency are scoped per caller and a reader who has not
    signed in is metered on the device rather than against an account.
    """

    model_config = ConfigDict(extra="forbid")

    selection: str
    clientLookupId: str
    platform: Literal["android", "ios"]
    locale: str
    consentModelProcessing: bool
    subject: str
    isAnonymous: bool = False

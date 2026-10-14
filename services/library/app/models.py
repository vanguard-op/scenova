"""Wire models for the shared word-clip library.

The stored records are the `schema.md` entities "LibraryEntry" and "ClipAsset".
The entry carries one extra field the clip cannot carry on its own — the delivery
`url` and whether the clip has audio — because the lookup service serves both on
the reading path. The response models are deliberately narrow: a caller asks what
the library holds for a sense and gets the entry the store kept, its status, and
the clip to serve.

The internal interface is not a numbered contract; the lookup and pipeline
services are its only callers and both speak this shape.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class PartOfSpeech(StrEnum):
    """Part of speech for a sense, matching the LibraryEntry schema."""

    NOUN = "noun"
    VERB = "verb"
    ADJECTIVE = "adjective"
    ADVERB = "adverb"
    PREPOSITION = "preposition"
    OTHER = "other"


class EntryStatus(StrEnum):
    """Whether an entry is served, held after a report, or retired (schema)."""

    ACTIVE = "active"
    HELD = "held"
    RETIRED = "retired"


class EntrySource(StrEnum):
    """Whether an entry was seeded before launch or generated from a lookup."""

    SEEDED = "seeded"
    GENERATED = "generated"


class ClipAssetBody(BaseModel):
    """A generated word clip stored centrally (schema "ClipAsset")."""

    model_config = ConfigDict(extra="forbid")

    id: str
    # The pinned clip model produces three to four seconds (schema "ClipAsset"),
    # so an asset outside that range is refused before it is stored.
    durationSeconds: float = Field(ge=3, le=4)
    resolution: Literal["360p"] = "360p"
    storageKey: str
    url: str
    hasAudio: bool
    synthIdWatermark: bool
    createdAt: str


class LibraryEntryBody(BaseModel):
    """A shared library entry keyed by lemma and sense (schema "LibraryEntry")."""

    model_config = ConfigDict(extra="forbid")

    id: str
    lemma: str
    partOfSpeech: PartOfSpeech
    senseLabel: str
    glossPhrase: str = Field(max_length=60)
    clipAssetId: str
    status: EntryStatus
    source: EntrySource
    createdAt: str
    updatedAt: str


class StoreEntryRequest(BaseModel):
    """Write one entry and the clip asset it references."""

    model_config = ConfigDict(extra="forbid")

    entry: LibraryEntryBody
    asset: ClipAssetBody


class StoreEntryResponse(BaseModel):
    """The acknowledgement for a stored entry."""

    model_config = ConfigDict(extra="forbid")

    entryId: str
    status: EntryStatus


class ServedClip(BaseModel):
    """The clip fields the lookup serves for a sense (C-001 `clip`)."""

    model_config = ConfigDict(extra="forbid")

    url: str
    durationSeconds: float
    resolution: Literal["360p"] = "360p"
    hasAudio: bool


class ServedEntry(BaseModel):
    """What the library holds for one sense.

    `status` travels with the entry: a held or retired entry is still returned so
    the caller can tell it apart from an absent one and start a replacement,
    while never serving it.
    """

    model_config = ConfigDict(extra="forbid")

    entryId: str
    status: EntryStatus
    glossPhrase: str
    clip: ServedClip


class FindEntryResponse(BaseModel):
    """The lookup for a sense key; `entry` is null when the library holds none."""

    model_config = ConfigDict(extra="forbid")

    entry: ServedEntry | None


class EntryDetail(BaseModel):
    """An entry addressed by id, with the word, sense, and clip it holds.

    The content review service reads an entry by id to show a curator the word,
    sense, generation phrase, and clip behind a queued report; the sense key it
    was stored under is not known to the review queue, which holds only the entry
    id.
    """

    model_config = ConfigDict(extra="forbid")

    entryId: str
    lemma: str
    senseLabel: str
    partOfSpeech: PartOfSpeech
    glossPhrase: str
    status: EntryStatus
    clip: ServedClip


class GetEntryResponse(BaseModel):
    """An entry addressed by id."""

    model_config = ConfigDict(extra="forbid")

    entry: EntryDetail


class UpdateEntryRequest(BaseModel):
    """A review action on an entry: hold it, retire it, or restore it."""

    model_config = ConfigDict(extra="forbid")

    status: EntryStatus


class UpdateEntryResponse(BaseModel):
    """The entry's status after the review action."""

    model_config = ConfigDict(extra="forbid")

    entryId: str
    status: EntryStatus

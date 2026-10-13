"""Lookup orchestration: normalise a selection, choose senses, resolve clips.

FEAT-003 lives here. A word lookup reduces to its base form and returns the
common senses; a word absent from the inventory keeps the word as the key and is
flagged as a best guess; a two-to-six-word selection is routed to the phrase
path; punctuation-only selections resolve empty; and an unavailable inventory
falls back to the word as the key.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from uuid import uuid4

from .errors import (
    ClientLookupIdConflictError,
    EmptySelectionError,
    LookupNotFoundError,
    PhraseLimitExceededError,
)
from .inventory import (
    InventoryUnavailableError,
    SenseInventory,
    SenseRecord,
    build_default_inventory,
)
from .library import InMemoryLibrary, LibraryEntry, LibraryPort
from .models import (
    Clip,
    CreateLookupRequest,
    Kind,
    LookupResponse,
    LookupStatus,
    PartOfSpeech,
    Sense,
)
from .normalisation import MAX_PHRASE_WORDS, tokenise
from .store import InMemoryLookupStore, LookupStore, StoredLookup

BEST_GUESS_NOTICE = (
    "This word isn't in our sense list yet, so we're showing the most likely meaning."
)
INVENTORY_UNAVAILABLE_NOTICE = (
    "Our sense list is temporarily unavailable, so we're showing the most likely meaning."
)
EMPTY_NOTICE = "There was nothing to look up in that selection."


class LookupService:
    """Normalises selections and records lookups against the shared library."""

    def __init__(
        self,
        *,
        inventory: SenseInventory,
        store: LookupStore,
        library: LibraryPort,
    ) -> None:
        self._inventory = inventory
        self._store = store
        self._library = library
        # Serialises the idempotency check and the write, so a duplicate
        # clientLookupId is replayed rather than recorded twice.
        self._write_lock = asyncio.Lock()

    async def create_lookup(
        self, request: CreateLookupRequest, correlation_id: str
    ) -> LookupResponse:
        raw_selection = request.selection.strip()
        async with self._write_lock:
            existing = await self._store.find_by_client_id(request.subject, request.clientLookupId)
            if existing is not None:
                if existing.raw_selection != raw_selection:
                    raise ClientLookupIdConflictError(
                        "This clientLookupId was already used with a different selection."
                    )
                return existing.to_response(correlation_id)
            stored = await self._resolve(request, raw_selection)
            await self._store.add(stored)
        return stored.to_response(correlation_id)

    async def get_lookup(self, lookup_id: str, subject: str, correlation_id: str) -> LookupResponse:
        stored = await self._store.get(lookup_id)
        if stored is None or stored.subject != subject:
            raise LookupNotFoundError("No lookup was found for this id.")
        return stored.to_response(correlation_id)

    async def _resolve(self, request: CreateLookupRequest, raw_selection: str) -> StoredLookup:
        if raw_selection == "":
            raise EmptySelectionError("The selection was empty.")
        tokens = tokenise(request.selection)
        if not tokens:
            return self._empty_lookup(request, raw_selection)
        if len(tokens) > MAX_PHRASE_WORDS:
            raise PhraseLimitExceededError(
                f"A selection of {len(tokens)} words is over the "
                f"{MAX_PHRASE_WORDS}-word phrase limit."
            )
        if len(tokens) == 1:
            return await self._word_lookup(request, raw_selection, tokens[0])
        return self._phrase_lookup(request, raw_selection)

    async def _word_lookup(
        self, request: CreateLookupRequest, raw_selection: str, token: str
    ) -> StoredLookup:
        notice: str | None = None
        try:
            resolved = self._inventory.resolve(token)
        except InventoryUnavailableError:
            resolved = None
            notice = INVENTORY_UNAVAILABLE_NOTICE
        if resolved is None:
            lemma = token
            records: tuple[SenseRecord, ...] = (_best_guess_sense(token),)
            if notice is None:
                notice = BEST_GUESS_NOTICE
        else:
            lemma = resolved.lemma
            records = resolved.senses
        senses = tuple([await self._sense(lemma, record) for record in records])
        status = _word_status(request.consentModelProcessing, senses)
        return _stored(request, raw_selection, Kind.WORD, lemma, status, senses, notice)

    async def _sense(self, lemma: str, record: SenseRecord) -> Sense:
        entry = await self._library.find(lemma, record.sense_label, record.part_of_speech)
        if entry is None:
            return Sense(
                senseLabel=record.sense_label,
                partOfSpeech=record.part_of_speech,
                glossPhrase=record.gloss_phrase,
                entryId=None,
                clip=None,
            )
        return Sense(
            senseLabel=record.sense_label,
            partOfSpeech=record.part_of_speech,
            glossPhrase=entry.gloss_phrase,
            entryId=entry.id,
            clip=_clip(entry),
        )

    def _phrase_lookup(self, request: CreateLookupRequest, raw_selection: str) -> StoredLookup:
        status = LookupStatus.GENERATING if request.consentModelProcessing else LookupStatus.DENIED
        return _stored(request, raw_selection, Kind.PHRASE, None, status, (), None)

    def _empty_lookup(self, request: CreateLookupRequest, raw_selection: str) -> StoredLookup:
        return _stored(
            request, raw_selection, Kind.WORD, None, LookupStatus.EMPTY, (), EMPTY_NOTICE
        )


def build_default_service() -> LookupService:
    """Build the lookup service with its seeded inventory and in-memory stores."""

    return LookupService(
        inventory=build_default_inventory(),
        store=InMemoryLookupStore(),
        library=InMemoryLibrary(),
    )


def _word_status(consent: bool, senses: tuple[Sense, ...]) -> LookupStatus:
    if senses and all(sense.clip is not None for sense in senses):
        return LookupStatus.SERVED
    if consent:
        return LookupStatus.GENERATING
    return LookupStatus.DENIED


def _best_guess_sense(token: str) -> SenseRecord:
    return SenseRecord(
        part_of_speech=PartOfSpeech.OTHER,
        sense_label="best_guess",
        gloss_phrase=token[:60],
        rank=0,
    )


def _clip(entry: LibraryEntry) -> Clip:
    return Clip(
        url=entry.clip.url,
        durationSeconds=entry.clip.duration_seconds,
        resolution=entry.clip.resolution,
        hasAudio=entry.clip.has_audio,
    )


def _stored(
    request: CreateLookupRequest,
    raw_selection: str,
    kind: Kind,
    lemma: str | None,
    status: LookupStatus,
    senses: tuple[Sense, ...],
    notice: str | None,
) -> StoredLookup:
    return StoredLookup(
        id=f"lk_{uuid4().hex}",
        subject=request.subject,
        client_lookup_id=request.clientLookupId,
        raw_selection=raw_selection,
        kind=kind,
        normalised_lemma=lemma,
        status=status,
        senses=senses,
        notice=notice,
        created_at=datetime.now(UTC).isoformat(),
    )

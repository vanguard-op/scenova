"""Lookup orchestration: normalise a selection, choose senses, resolve clips.

FEAT-003 lives here. A word lookup reduces to its base form and returns the
common senses; a word absent from the inventory keeps the word as the key and is
flagged as a best guess; a two-to-six-word selection is routed to the phrase
path; punctuation-only selections resolve empty; and an unavailable inventory
falls back to the word as the key.

FEAT-005 is wired here: a sense the library cannot serve is handed to the
generation pipeline (C-003), so a later poll of the lookup (C-002) serves the
clip the pipeline wrote to the shared library. When the pipeline cannot accept
the job the reader still gets the word and phrase, marked as the fallback.
"""

from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import UTC, datetime
from uuid import uuid4

from .config import Settings
from .errors import (
    ClientLookupIdConflictError,
    EmptySelectionError,
    LookupNotFoundError,
    PhraseLimitExceededError,
)
from .generation import (
    CLIP_TARGET_SECONDS,
    DEFAULT_MODEL_PIN,
    GenerationAlreadyEnqueuedError,
    GenerationClient,
    GenerationJob,
    GenerationUnavailableError,
    HttpGenerationClient,
    phrase_job_id,
    word_job_id,
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
GENERATION_UNAVAILABLE_NOTICE = (
    "We couldn't start a clip for this one. Please try again in a moment."
)
EMPTY_NOTICE = "There was nothing to look up in that selection."

# A phrase has no sense, but C-003 requires a sense label; this marks the job as
# the phrase path.
PHRASE_SENSE_LABEL = "phrase"


class LookupService:
    """Normalises selections and records lookups against the shared library."""

    def __init__(
        self,
        *,
        inventory: SenseInventory,
        store: LookupStore,
        library: LibraryPort,
        generation: GenerationClient,
        model_pin: str = DEFAULT_MODEL_PIN,
        generation_target_duration_seconds: float = CLIP_TARGET_SECONDS,
    ) -> None:
        self._inventory = inventory
        self._store = store
        self._library = library
        self._generation = generation
        self._model_pin = model_pin
        self._target_duration = generation_target_duration_seconds
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
        refreshed = await self._refresh(stored)
        if refreshed is not stored:
            # The library served a clip that was missing when the lookup was
            # first made, so the improved record is kept for the next poll.
            await self._store.add(refreshed)
        return refreshed.to_response(correlation_id)

    async def aclose(self) -> None:
        """Release the generation client's connections."""

        await self._generation.aclose()

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
        return await self._phrase_lookup(request, raw_selection, " ".join(tokens))

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
        lookup_id = _new_id()
        if status is LookupStatus.GENERATING:
            missing = [
                record for record, sense in zip(records, senses, strict=True) if sense.clip is None
            ]
            jobs = _word_jobs(
                lookup_id,
                lemma,
                missing,
                model_pin=self._model_pin,
                target_duration=self._target_duration,
            )
            if not await self._enqueue(jobs):
                status = LookupStatus.FALLBACK
                notice = GENERATION_UNAVAILABLE_NOTICE
        return _stored(lookup_id, request, raw_selection, Kind.WORD, lemma, status, senses, notice)

    async def _phrase_lookup(
        self, request: CreateLookupRequest, raw_selection: str, phrase: str
    ) -> StoredLookup:
        lookup_id = _new_id()
        if not request.consentModelProcessing:
            return _stored(
                lookup_id, request, raw_selection, Kind.PHRASE, None, LookupStatus.DENIED, (), None
            )
        job = GenerationJob(
            job_id=phrase_job_id(lookup_id),
            lookup_id=lookup_id,
            kind=Kind.PHRASE,
            lemma=None,
            phrase=phrase,
            sense_label=PHRASE_SENSE_LABEL,
            part_of_speech=PartOfSpeech.OTHER,
            target_duration_seconds=self._target_duration,
            model_pin=self._model_pin,
        )
        if await self._enqueue([job]):
            return _stored(
                lookup_id,
                request,
                raw_selection,
                Kind.PHRASE,
                None,
                LookupStatus.GENERATING,
                (),
                None,
            )
        return _stored(
            lookup_id,
            request,
            raw_selection,
            Kind.PHRASE,
            None,
            LookupStatus.FALLBACK,
            (),
            GENERATION_UNAVAILABLE_NOTICE,
        )

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
        return _served_sense(record.sense_label, record.part_of_speech, entry)

    async def _enqueue(self, jobs: list[GenerationJob]) -> bool:
        """Hand jobs to the pipeline; False when one cannot be accepted."""

        for job in jobs:
            try:
                await self._generation.enqueue(job)
            except GenerationAlreadyEnqueuedError:
                # Another lookup for the same key already started this
                # generation; both lookups are served by its result.
                continue
            except GenerationUnavailableError:
                return False
        return True

    async def _refresh(self, stored: StoredLookup) -> StoredLookup:
        """Serve a clip the library has gained since the lookup was recorded."""

        if stored.kind is not Kind.WORD or not stored.senses:
            return stored
        lemma = stored.normalised_lemma or stored.raw_selection
        senses = tuple([await self._refresh_sense(lemma, sense) for sense in stored.senses])
        if senses == stored.senses:
            return stored
        if all(sense.clip is not None for sense in senses):
            return replace(stored, senses=senses, status=LookupStatus.SERVED)
        return replace(stored, senses=senses)

    async def _refresh_sense(self, lemma: str, sense: Sense) -> Sense:
        if sense.clip is not None:
            return sense
        entry = await self._library.find(lemma, sense.senseLabel, sense.partOfSpeech)
        if entry is None:
            return sense
        return _served_sense(sense.senseLabel, sense.partOfSpeech, entry)

    def _empty_lookup(self, request: CreateLookupRequest, raw_selection: str) -> StoredLookup:
        return _stored(
            _new_id(),
            request,
            raw_selection,
            Kind.WORD,
            None,
            LookupStatus.EMPTY,
            (),
            EMPTY_NOTICE,
        )


def build_default_service(settings: Settings | None = None) -> LookupService:
    """Build the lookup service with its seeded inventory, stores, and pipeline client."""

    resolved = settings or Settings.from_env()
    return LookupService(
        inventory=build_default_inventory(),
        store=InMemoryLookupStore(),
        library=InMemoryLibrary(),
        generation=HttpGenerationClient(
            base_url=resolved.pipeline_base_url,
            internal_audience=resolved.internal_audience,
            timeout_seconds=resolved.pipeline_timeout_seconds,
        ),
        model_pin=resolved.model_pin,
        generation_target_duration_seconds=resolved.generation_target_duration_seconds,
    )


def _word_jobs(
    lookup_id: str,
    lemma: str,
    records: list[SenseRecord],
    *,
    model_pin: str,
    target_duration: float,
) -> list[GenerationJob]:
    return [
        GenerationJob(
            job_id=word_job_id(lemma, record.sense_label, record.part_of_speech),
            lookup_id=lookup_id,
            kind=Kind.WORD,
            lemma=lemma,
            phrase=record.gloss_phrase,
            sense_label=record.sense_label,
            part_of_speech=record.part_of_speech,
            target_duration_seconds=target_duration,
            model_pin=model_pin,
        )
        for record in records
    ]


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


def _served_sense(sense_label: str, part_of_speech: PartOfSpeech, entry: LibraryEntry) -> Sense:
    return Sense(
        senseLabel=sense_label,
        partOfSpeech=part_of_speech,
        glossPhrase=entry.gloss_phrase,
        entryId=entry.id,
        clip=_clip(entry),
    )


def _clip(entry: LibraryEntry) -> Clip:
    return Clip(
        url=entry.clip.url,
        durationSeconds=entry.clip.duration_seconds,
        resolution=entry.clip.resolution,
        hasAudio=entry.clip.has_audio,
    )


def _new_id() -> str:
    return f"lk_{uuid4().hex}"


def _stored(
    lookup_id: str,
    request: CreateLookupRequest,
    raw_selection: str,
    kind: Kind,
    lemma: str | None,
    status: LookupStatus,
    senses: tuple[Sense, ...],
    notice: str | None,
) -> StoredLookup:
    return StoredLookup(
        id=lookup_id,
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

"""Lookup orchestration: normalise a selection, choose senses, resolve clips.

FEAT-003 lives here. A word lookup reduces to its base form and returns the
common senses; a word absent from the inventory keeps the word as the key; a
two-to-six-word selection is routed to the phrase path; punctuation-only
selections resolve empty; and an unavailable inventory falls back to the word as
the key. A lookup carries no notice about the meaning itself: `notice` is for
clip availability only.

FEAT-005 is wired here: a sense the library cannot serve is handed to the
generation pipeline (C-003), so a later poll of the lookup (C-002) serves the
clip the pipeline wrote to the shared library. When the pipeline cannot accept
the job the reader still gets the word and phrase, marked as the fallback.

FEAT-006 is wired here too. The shared library is read on the fast path: an
active entry is served without a generation, a retired one is a miss whose id
seeds the replacement, and an unreachable library falls back to generation
rather than failing the reader.

FEAT-007's `enable_phrase_clip` release flag is honoured here: when it is off, a
short phrase is not routed to the phrase path and falls back to the word path, so
the reader still gets the phrase as a word lookup and no phrase clip is started
(release.md "Rollout Phases & Feature Flags").

FEAT-013 is metered here. A signed-in reader's lookup spends one unit of their
monthly allowance before it serves or generates, so a hit and a miss cost the
same (monetization.md "Revenue Model"), and the C-001 body carries the allowance
back. When the allowance is spent the lookup resolves to the fallback with the
word and phrase and no clip, and `allowance.used` equals `allowance.limit` so the
client can offer a way to add more. A reader who has not signed in is metered on
the device and carries no allowance; an unreachable meter is a grace path, never
a block (NFR-011).
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from uuid import uuid4

from .config import CLIP_MODEL_PIN, Settings
from .db import create_engine
from .entitlement import (
    EntitlementPort,
    EntitlementUnavailableError,
    HttpEntitlement,
)
from .errors import (
    ClientLookupIdConflictError,
    EmptySelectionError,
    LookupNotFoundError,
    PhraseLimitExceededError,
)
from .generation import (
    CLIP_TARGET_SECONDS,
    GenerationAlreadyEnqueuedError,
    GenerationClient,
    GenerationJob,
    GenerationJobStatus,
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
from .library import (
    HttpLibrary,
    LibraryEntry,
    LibraryEntryStatus,
    LibraryPort,
    LibraryUnavailableError,
)
from .models import (
    Allowance,
    Clip,
    CreateLookupRequest,
    CreateLookupResponse,
    Kind,
    LookupResponse,
    LookupStatus,
    PartOfSpeech,
    Sense,
)
from .normalisation import MAX_PHRASE_WORDS, tokenise
from .store import InMemoryLookupStore, LookupStore, PostgresLookupStore, StoredLookup

GENERATION_UNAVAILABLE_NOTICE = (
    "We couldn't start a clip for this one. Please try again in a moment."
)
GENERATION_FAILED_NOTICE = "We couldn't make a clip for this one. Please try again."
EMPTY_NOTICE = "There was nothing to look up in that selection."

# The sense label shown for a word outside the sense inventory. It is a plain
# human label for the key, not a signal about how sure the meaning is.
OUT_OF_INVENTORY_SENSE_LABEL = "meaning"

# A phrase has no sense, but C-003 requires a sense label; this marks the job as
# the phrase path.
PHRASE_SENSE_LABEL = "phrase"

# A job in one of these states produced no clip and never will (C-006).
_STOPPED_WITHOUT_CLIP = frozenset({GenerationJobStatus.FAILED, GenerationJobStatus.DECLINED})


@dataclass(frozen=True)
class _SenseResolution:
    """One sense resolved against the shared library.

    ``sense`` is what the reader is served, with its clip when the library held an
    active entry. ``regeneration_seed`` is the id of a retired entry the miss
    superseded, which salts the replacement job so it is not refused as a
    duplicate (FEAT-006).
    """

    sense: Sense
    regeneration_seed: str | None


@dataclass(frozen=True)
class _MeterReading:
    """What the allowance meter said before a lookup resolved.

    ``allowed`` is False only when the reader's allowance is spent; ``allowance``
    is the reading carried back to the client, and is None for a reader who is
    not signed in or whose meter could not be reached.
    """

    allowed: bool
    allowance: Allowance | None


class LookupService:
    """Normalises selections and records lookups against the shared library."""

    def __init__(
        self,
        *,
        inventory: SenseInventory,
        store: LookupStore,
        library: LibraryPort,
        generation: GenerationClient,
        entitlement: EntitlementPort,
        clip_model_pin: str = CLIP_MODEL_PIN,
        generation_target_duration_seconds: float = CLIP_TARGET_SECONDS,
        enable_phrase_clip: bool = True,
    ) -> None:
        self._inventory = inventory
        self._store = store
        self._library = library
        self._generation = generation
        self._entitlement = entitlement
        self._clip_model_pin = clip_model_pin
        self._target_duration = generation_target_duration_seconds
        self._enable_phrase_clip = enable_phrase_clip
        # Serialises the idempotency check and the write, so a duplicate
        # clientLookupId is replayed rather than recorded twice.
        self._write_lock = asyncio.Lock()

    async def create_lookup(
        self, request: CreateLookupRequest, correlation_id: str
    ) -> CreateLookupResponse:
        raw_selection = request.selection.strip()
        async with self._write_lock:
            existing = await self._store.find_by_client_id(request.subject, request.clientLookupId)
            if existing is not None:
                if existing.raw_selection != raw_selection:
                    raise ClientLookupIdConflictError(
                        "This clientLookupId was already used with a different selection."
                    )
                return existing.to_create_response(correlation_id)
            stored = await self._create(request, raw_selection)
            await self._store.add(stored)
        return stored.to_create_response(correlation_id)

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

    async def anonymize_subject(self, subject: str) -> int:
        """Anonymize the reader's lookups after their account is deleted.

        A lookup is personal data (schema "Lookup"), so a data-subject deletion
        strips the selection and the identity from the reader's records rather
        than leaving them beside a live account id (nfr.md "Privacy &
        Compliance"). It is idempotent, so a re-run for a reader whose records
        were already anonymized finds nothing and reports zero.
        """

        async with self._write_lock:
            return await self._store.anonymize_subject(subject)

    async def aclose(self) -> None:
        """Release the store, generation, library, and meter clients' connections."""

        await self._store.aclose()
        await self._library.aclose()
        await self._generation.aclose()
        await self._entitlement.aclose()

    async def _create(self, request: CreateLookupRequest, raw_selection: str) -> StoredLookup:
        """Validate a selection, spend its allowance, and resolve it.

        Validation runs before the spend, so a malformed selection costs the
        reader nothing; a punctuation-only selection resolves empty and spends
        nothing because there was no word or phrase to look up.
        """

        if raw_selection == "":
            raise EmptySelectionError("The selection was empty.")
        tokens = tokenise(request.selection)
        if len(tokens) > MAX_PHRASE_WORDS:
            raise PhraseLimitExceededError(
                f"A selection of {len(tokens)} words is over the "
                f"{MAX_PHRASE_WORDS}-word phrase limit."
            )
        if not tokens:
            return self._empty_lookup(request, raw_selection)

        reading = await self._meter(request)
        account_id = _account_id(request, reading)
        if not reading.allowed:
            exhausted = self._exhausted_lookup(request, raw_selection, tokens, reading.allowance)
            return replace(exhausted, account_id=account_id)

        stored = await self._resolve(request, raw_selection, tokens)
        return replace(stored, allowance=reading.allowance, account_id=account_id)

    async def _meter(self, request: CreateLookupRequest) -> _MeterReading:
        """Spend one unit of a signed-in reader's allowance, or read the grace path.

        A reader who has not signed in holds no account here, so nothing is
        spent and the response carries no allowance. When the meter cannot be
        reached the lookup proceeds and the allowance is left to the client to
        reconcile, so a metering fault never blocks the reader (NFR-011).
        """

        if request.isAnonymous:
            return _MeterReading(allowed=True, allowance=None)
        try:
            outcome = await self._entitlement.spend(request.subject, request.clientLookupId)
        except EntitlementUnavailableError:
            return _MeterReading(allowed=True, allowance=None)
        return _MeterReading(
            allowed=outcome.allowed,
            allowance=Allowance(
                used=outcome.lookups_used,
                limit=outcome.lookups_limit,
                periodEnd=outcome.period_end,
            ),
        )

    async def _resolve(
        self, request: CreateLookupRequest, raw_selection: str, tokens: list[str]
    ) -> StoredLookup:
        if len(tokens) == 1:
            return await self._word_lookup(request, raw_selection, tokens[0])
        phrase = " ".join(tokens)
        if not self._enable_phrase_clip:
            # The phrase-clip kill switch is off: no phrase job is started and the
            # phrase falls back to the word path, where it is looked up as a
            # single key (release.md "Rollout Phases & Feature Flags").
            return await self._word_lookup(request, raw_selection, phrase)
        return await self._phrase_lookup(request, raw_selection, phrase)

    def _inventory_key(self, token: str) -> tuple[str, tuple[SenseRecord, ...]]:
        """The library key for a word, and the senses to resolve for it.

        A word absent from the inventory, or an inventory that cannot be
        reached, keeps the word as the key with a single neutral sense
        (FEAT-003).
        """

        try:
            resolved = self._inventory.resolve(token)
        except InventoryUnavailableError:
            resolved = None
        if resolved is None:
            return token, (_out_of_inventory_sense(token),)
        return resolved.lemma, resolved.senses

    async def _word_lookup(
        self, request: CreateLookupRequest, raw_selection: str, token: str
    ) -> StoredLookup:
        notice: str | None = None
        lemma, records = self._inventory_key(token)
        resolved_senses = [await self._sense(lemma, record) for record in records]
        senses = tuple(resolution.sense for resolution in resolved_senses)
        status = _word_status(request.consentModelProcessing, senses)
        lookup_id = _new_id()
        job_ids: tuple[str, ...] = ()
        if status is LookupStatus.GENERATING:
            missing = [
                (record, resolution.regeneration_seed)
                for record, resolution in zip(records, resolved_senses, strict=True)
                if resolution.sense.clip is None
            ]
            jobs = _word_jobs(
                lookup_id,
                lemma,
                missing,
                model_pin=self._clip_model_pin,
                target_duration=self._target_duration,
            )
            if not await self._enqueue(jobs):
                status = LookupStatus.FALLBACK
                notice = GENERATION_UNAVAILABLE_NOTICE
            else:
                job_ids = tuple(job.job_id for job in jobs)
        return _stored(
            lookup_id,
            request,
            raw_selection,
            Kind.WORD,
            lemma,
            status,
            senses,
            notice,
            generation_job_ids=job_ids,
        )

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
            model_pin=self._clip_model_pin,
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
                generation_job_ids=(job.job_id,),
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

    def _exhausted_lookup(
        self,
        request: CreateLookupRequest,
        raw_selection: str,
        tokens: list[str],
        allowance: Allowance | None,
    ) -> StoredLookup:
        """The lookup a reader gets when their allowance is spent (FEAT-013).

        The word and phrase still show; no clip is served or generated, so a
        library hit is withheld too and the reader is not charged again. The
        allowance comes back with `used` equal to `limit`, which is the client's
        signal to offer a way to add more. A phrase selection keeps its kind and
        no senses, like any phrase lookup.
        """

        if len(tokens) > 1 and self._enable_phrase_clip:
            return _stored(
                _new_id(),
                request,
                raw_selection,
                Kind.PHRASE,
                None,
                LookupStatus.FALLBACK,
                (),
                None,
                allowance=allowance,
            )
        key = tokens[0] if len(tokens) == 1 else " ".join(tokens)
        lemma, records = self._inventory_key(key)
        return _stored(
            _new_id(),
            request,
            raw_selection,
            Kind.WORD,
            lemma,
            LookupStatus.FALLBACK,
            tuple(_miss_sense(record) for record in records),
            None,
            allowance=allowance,
        )

    async def _sense(self, lemma: str, record: SenseRecord) -> _SenseResolution:
        """Resolve one sense to a served clip, a miss, and a regeneration seed.

        Only an active entry is served. A retired entry is a miss whose id seeds
        the replacement generation, so the retired clip is not served and a new
        one can be produced (FEAT-006). An unreachable library is a miss too: the
        lookup falls back to generation rather than failing.
        """

        try:
            entry = await self._library.find(lemma, record.sense_label, record.part_of_speech)
        except LibraryUnavailableError:
            return _SenseResolution(_miss_sense(record), None)
        if entry is None:
            return _SenseResolution(_miss_sense(record), None)
        if entry.status is not LibraryEntryStatus.ACTIVE:
            return _SenseResolution(_miss_sense(record), entry.id)
        return _SenseResolution(
            _served_sense(record.sense_label, record.part_of_speech, entry),
            None,
        )

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
        """Resolve a poll against the library and the pipeline's job states.

        A clip the library gained is served; a generation that stopped without a
        clip (C-006 failed or declined, or a job the pipeline no longer knows)
        resolves the lookup to the fallback (FEAT-005).
        """

        if stored.kind is Kind.PHRASE:
            return await self._refresh_phrase(stored)
        if stored.kind is Kind.WORD and stored.senses:
            return await self._refresh_word(stored)
        return stored

    async def _refresh_word(self, stored: StoredLookup) -> StoredLookup:
        lemma = stored.normalised_lemma or stored.raw_selection
        senses = tuple([await self._refresh_sense(lemma, sense) for sense in stored.senses])
        if all(sense.clip is not None for sense in senses):
            if senses == stored.senses and stored.status is LookupStatus.SERVED:
                return stored
            return replace(stored, senses=senses, status=LookupStatus.SERVED)
        if stored.status is LookupStatus.GENERATING and await self._generation_stopped(
            stored.generation_job_ids
        ):
            return replace(
                stored,
                senses=senses,
                status=LookupStatus.FALLBACK,
                notice=GENERATION_FAILED_NOTICE,
            )
        if senses == stored.senses:
            return stored
        return replace(stored, senses=senses)

    async def _refresh_phrase(self, stored: StoredLookup) -> StoredLookup:
        if stored.status is LookupStatus.GENERATING and await self._generation_stopped(
            stored.generation_job_ids
        ):
            return replace(stored, status=LookupStatus.FALLBACK, notice=GENERATION_FAILED_NOTICE)
        return stored

    async def _generation_stopped(self, job_ids: tuple[str, ...]) -> bool:
        """True when a generation stopped without a clip and none is still running.

        A job the pipeline no longer knows (C-006 404) has stopped too. A
        transient pipeline error is not a failure: the lookup keeps generating
        rather than dropping the reader to the fallback on a blip.
        """

        stopped = False
        for job_id in job_ids:
            try:
                status = await self._generation.status(job_id)
            except GenerationUnavailableError:
                return False
            if status is None or status in _STOPPED_WITHOUT_CLIP:
                stopped = True
            elif status in (GenerationJobStatus.QUEUED, GenerationJobStatus.RUNNING):
                return False
        return stopped

    async def _refresh_sense(self, lemma: str, sense: Sense) -> Sense:
        """Re-resolve one sense against the library.

        An already-served sense is left as it is. A retired entry and an
        unreachable library are both still a miss.
        """

        if sense.clip is not None:
            return sense
        try:
            entry = await self._library.find(lemma, sense.senseLabel, sense.partOfSpeech)
        except LibraryUnavailableError:
            return sense
        if entry is None or entry.status is not LibraryEntryStatus.ACTIVE:
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
    """Build the lookup service with its seeded inventory, stores, and clients.

    An environment with no `DATABASE_URL` keeps the in-memory store, so a bare
    local run and the unit tests need no database; every deployed environment
    resolves the relational store the primary database holds (architecture.md
    "Primary Database").
    """

    resolved = settings or Settings.from_env()
    store: LookupStore = (
        InMemoryLookupStore()
        if resolved.database_url is None
        else PostgresLookupStore(create_engine(resolved.database_url))
    )
    return LookupService(
        inventory=build_default_inventory(),
        store=store,
        library=HttpLibrary(
            base_url=resolved.library_base_url,
            internal_audience=resolved.internal_audience,
            timeout_seconds=resolved.library_timeout_seconds,
        ),
        generation=HttpGenerationClient(
            base_url=resolved.pipeline_base_url,
            internal_audience=resolved.internal_audience,
            timeout_seconds=resolved.pipeline_timeout_seconds,
        ),
        entitlement=HttpEntitlement(
            base_url=resolved.entitlement_base_url,
            internal_audience=resolved.internal_audience,
            timeout_seconds=resolved.entitlement_timeout_seconds,
        ),
        clip_model_pin=resolved.clip_model_pin,
        generation_target_duration_seconds=resolved.generation_target_duration_seconds,
        enable_phrase_clip=resolved.enable_phrase_clip,
    )


def _word_jobs(
    lookup_id: str,
    lemma: str,
    missing: list[tuple[SenseRecord, str | None]],
    *,
    model_pin: str,
    target_duration: float,
) -> list[GenerationJob]:
    # A word job leaves the phrase null: the pipeline generates the gloss phrase
    # from the word, its part of speech, and the sense hint (C-003, C-004). A miss
    # that superseded a held or retired entry salts the job id with that entry, so
    # the replacement is not refused as a duplicate generation (FEAT-006).
    return [
        GenerationJob(
            job_id=word_job_id(
                lemma,
                record.sense_label,
                record.part_of_speech,
                regeneration=seed,
            ),
            lookup_id=lookup_id,
            kind=Kind.WORD,
            lemma=lemma,
            phrase=None,
            sense_label=record.sense_label,
            part_of_speech=record.part_of_speech,
            target_duration_seconds=target_duration,
            model_pin=model_pin,
        )
        for record, seed in missing
    ]


def _account_id(request: CreateLookupRequest, reading: _MeterReading) -> str | None:
    """The account the lookup belongs to, or None.

    A reader who has not signed in holds no account. A signed-in reader's subject
    *is* the account id, but the account row is the entitlement service's to
    create: it exists once the meter has answered for this reader, so the account
    is recorded only then. The documented grace path (NFR-011) leaves it null
    rather than pointing at an account that may not be there yet, which the schema
    allows for a guest or a pre-account lookup (schema "Lookup": `accountId`).
    """

    if request.isAnonymous or reading.allowance is None:
        return None
    return request.subject


def _word_status(consent: bool, senses: tuple[Sense, ...]) -> LookupStatus:
    if senses and all(sense.clip is not None for sense in senses):
        return LookupStatus.SERVED
    if consent:
        return LookupStatus.GENERATING
    return LookupStatus.DENIED


def _out_of_inventory_sense(token: str) -> SenseRecord:
    return SenseRecord(
        part_of_speech=PartOfSpeech.OTHER,
        sense_label=OUT_OF_INVENTORY_SENSE_LABEL,
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


def _miss_sense(record: SenseRecord) -> Sense:
    """The word and phrase a reader sees while the clip is missing (no clip)."""

    return Sense(
        senseLabel=record.sense_label,
        partOfSpeech=record.part_of_speech,
        glossPhrase=record.gloss_phrase,
        entryId=None,
        clip=None,
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
    *,
    generation_job_ids: tuple[str, ...] = (),
    allowance: Allowance | None = None,
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
        generation_job_ids=generation_job_ids,
        allowance=allowance,
    )

"""Lookup records and idempotency (schema "Lookup").

The record is the reader's lookup as it resolved, rebuilt into a response per
request: what was selected, what it reduced to, the senses served, the
generation jobs a poll is waiting on, and the allowance it was metered against.
Two implementations sit behind one port: the in-memory store the unit tests use,
and the relational store that is the primary database (architecture.md "Primary
Database").

A lookup is personal data (schema "Lookup": `accountId`, `rawSelection`,
`normalisedLemma`), so a data-subject deletion anonymizes the reader's lookups
rather than keeping the selection beside a severed identity (nfr.md "Privacy &
Compliance"; analytics.md "Analytics Data Governance"). The record keeps its
outcome and timestamps so usage survives as an anonymized count, while the
selection and the identity that ties it to a reader are gone.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, replace
from typing import Literal, Protocol, cast

from sqlalchemy import Select, select
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .db import LookupJobRow, LookupRow, LookupSenseRow
from .errors import LookupUnavailableError
from .models import (
    Allowance,
    Clip,
    CreateLookupResponse,
    Kind,
    LookupResponse,
    LookupStatus,
    PartOfSpeech,
    Sense,
)

# The subject an anonymized lookup is left under. It is a sentinel no reader can
# hold, so ownership checks can never reattach the record to an identity.
ANONYMIZED_SUBJECT = "deleted"


@dataclass(frozen=True)
class StoredLookup:
    """A lookup as recorded, rebuilt into a response per request."""

    id: str
    subject: str
    client_lookup_id: str
    raw_selection: str
    kind: Kind
    normalised_lemma: str | None
    status: LookupStatus
    senses: tuple[Sense, ...]
    notice: str | None
    created_at: str
    # The account that made the lookup, or None for a guest or a pre-account
    # lookup (schema "Lookup": `accountId`).
    account_id: str | None = None
    # The pipeline jobs this lookup is waiting on, so a poll can ask whether any
    # has stopped without a clip (C-006, FEAT-005).
    generation_job_ids: tuple[str, ...] = ()
    # The reader's allowance as it read when this lookup was made, kept so a
    # resent create replays the same body (C-001); null for a reader who is not
    # signed in.
    allowance: Allowance | None = None

    def to_response(self, correlation_id: str) -> LookupResponse:
        """The C-002 body: a lookup read by id, which carries no allowance."""

        return LookupResponse(
            lookupId=self.id,
            kind=self.kind,
            rawSelection=self.raw_selection,
            normalisedLemma=self.normalised_lemma,
            status=self.status,
            senses=list(self.senses),
            notice=self.notice,
            correlationId=correlation_id,
        )

    def to_create_response(self, correlation_id: str) -> CreateLookupResponse:
        """The C-001 body: the lookup plus the allowance it was metered against."""

        return CreateLookupResponse(
            lookupId=self.id,
            kind=self.kind,
            rawSelection=self.raw_selection,
            normalisedLemma=self.normalised_lemma,
            status=self.status,
            senses=list(self.senses),
            notice=self.notice,
            correlationId=correlation_id,
            allowance=self.allowance,
        )


class LookupStore(Protocol):
    """Port for lookup persistence."""

    async def add(self, lookup: StoredLookup) -> None: ...

    async def get(self, lookup_id: str) -> StoredLookup | None: ...

    async def find_by_client_id(
        self, subject: str, client_lookup_id: str
    ) -> StoredLookup | None: ...

    async def anonymize_subject(self, subject: str) -> int:
        """Strip a subject's personal data from their lookups; return the count.

        The selection, the normalised lemma, and the senses that could restate
        the selection go, and the record is left under the anonymized sentinel so
        no identity is attached to it (schema "Lookup"; nfr.md "Privacy &
        Compliance"). The outcome and timestamps stay, so the reader's usage
        survives as an anonymized count.
        """
        ...

    async def aclose(self) -> None:
        """Release whatever the store holds open."""
        ...


class InMemoryLookupStore:
    """An in-memory lookup store, keyed by id and by caller plus idempotency key."""

    def __init__(self) -> None:
        self._by_id: dict[str, StoredLookup] = {}
        self._by_client: dict[tuple[str, str], StoredLookup] = {}

    async def add(self, lookup: StoredLookup) -> None:
        self._by_id[lookup.id] = lookup
        self._by_client[(lookup.subject, lookup.client_lookup_id)] = lookup

    async def get(self, lookup_id: str) -> StoredLookup | None:
        return self._by_id.get(lookup_id)

    async def find_by_client_id(self, subject: str, client_lookup_id: str) -> StoredLookup | None:
        return self._by_client.get((subject, client_lookup_id))

    async def anonymize_subject(self, subject: str) -> int:
        affected = [lookup for lookup in self._by_id.values() if lookup.subject == subject]
        for lookup in affected:
            anonymized = replace(
                lookup,
                subject=ANONYMIZED_SUBJECT,
                account_id=None,
                client_lookup_id="",
                raw_selection="",
                normalised_lemma=None,
                senses=(),
            )
            self._by_id[anonymized.id] = anonymized
            # The idempotency key belonged to the reader who made the lookup, so
            # it is dropped with them rather than left mapped to the record.
            self._by_client.pop((lookup.subject, lookup.client_lookup_id), None)
        return len(affected)

    async def aclose(self) -> None:
        return None


class PostgresLookupStore:
    """Lookup records in the primary relational database.

    The tables are the platform's migration history (`infra/db/migrations`), so
    the store maps them and never creates them. Each call runs its query on a
    worker thread, so a slow database never blocks the event loop the reader's
    lookup runs on (NFR-002). Every failure to reach the database is reported as
    the lookup being unavailable, so the API answers 503 for a retryable read or
    create rather than serving a lookup it could not record (C-001).
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def add(self, lookup: StoredLookup) -> None:
        await asyncio.to_thread(self._add, lookup)

    async def get(self, lookup_id: str) -> StoredLookup | None:
        return await asyncio.to_thread(self._get, lookup_id)

    async def find_by_client_id(self, subject: str, client_lookup_id: str) -> StoredLookup | None:
        return await asyncio.to_thread(self._find_by_client_id, subject, client_lookup_id)

    async def anonymize_subject(self, subject: str) -> int:
        return await asyncio.to_thread(self._anonymize_subject, subject)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    def _add(self, lookup: StoredLookup) -> None:
        try:
            with self._sessions() as session, session.begin():
                # A poll can replace a lookup whose clip arrived after it was
                # first made, so its senses and jobs are written afresh rather
                # than accumulated. The record's own row is updated in place: a
                # delete would cascade to every row that references the lookup —
                # the pipeline's generation jobs, the reader's feedback and
                # reports, their push registration and saved history (schema
                # "Relationships") — and take a generation that is still running
                # with it.
                row = session.get(LookupRow, lookup.id)
                if row is None:
                    session.add(_row(lookup))
                    return
                row.senses.clear()
                row.generation_jobs.clear()
                # The old child rows go before the new ones arrive: they share
                # the (lookup_id, position) key, so the two must not meet in one
                # flush.
                session.flush()
                _apply(row, lookup)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _get(self, lookup_id: str) -> StoredLookup | None:
        return self._fetch_one(select(LookupRow).where(LookupRow.id == lookup_id))

    def _find_by_client_id(self, subject: str, client_lookup_id: str) -> StoredLookup | None:
        return self._fetch_one(
            select(LookupRow).where(
                LookupRow.subject == subject,
                LookupRow.client_lookup_id == client_lookup_id,
            )
        )

    def _anonymize_subject(self, subject: str) -> int:
        try:
            with self._sessions() as session, session.begin():
                rows = session.scalars(select(LookupRow).where(LookupRow.subject == subject)).all()
                for row in rows:
                    row.subject = ANONYMIZED_SUBJECT
                    row.account_id = None
                    row.client_lookup_id = None
                    row.raw_selection = ""
                    row.normalised_lemma = None
                    # The senses restate the selection, so they go with it.
                    row.senses.clear()
                return len(rows)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _fetch_one(self, statement: Select[tuple[LookupRow]]) -> StoredLookup | None:
        try:
            with self._sessions() as session:
                row = session.scalar(statement)
                return None if row is None else _stored(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def _row(lookup: StoredLookup) -> LookupRow:
    row = LookupRow(id=lookup.id)
    _apply(row, lookup)
    return row


def _apply(row: LookupRow, lookup: StoredLookup) -> None:
    allowance = lookup.allowance
    row.subject = lookup.subject
    row.client_lookup_id = lookup.client_lookup_id or None
    row.account_id = lookup.account_id
    row.raw_selection = lookup.raw_selection
    row.kind = lookup.kind.value
    row.normalised_lemma = lookup.normalised_lemma
    # The entry a library hit was served from, so the lookup joins back to
    # the entry it used (schema "Lookup": `servedEntryId`).
    row.served_entry_id = _served_entry_id(lookup.senses)
    row.status = lookup.status.value
    row.notice = lookup.notice
    row.created_at = lookup.created_at
    row.allowance_used = None if allowance is None else allowance.used
    row.allowance_limit = None if allowance is None else allowance.limit
    row.allowance_period_end = None if allowance is None else allowance.periodEnd
    row.senses = [_sense_row(position, sense) for position, sense in enumerate(lookup.senses)]
    row.generation_jobs = [
        LookupJobRow(position=position, job_id=job_id)
        for position, job_id in enumerate(lookup.generation_job_ids)
    ]


def _served_entry_id(senses: tuple[Sense, ...]) -> str | None:
    return next((sense.entryId for sense in senses if sense.entryId is not None), None)


def _sense_row(position: int, sense: Sense) -> LookupSenseRow:
    clip = sense.clip
    return LookupSenseRow(
        position=position,
        sense_label=sense.senseLabel,
        part_of_speech=sense.partOfSpeech.value,
        gloss_phrase=sense.glossPhrase,
        entry_id=sense.entryId,
        clip_url=None if clip is None else clip.url,
        clip_duration_seconds=None if clip is None else clip.durationSeconds,
        clip_resolution=None if clip is None else clip.resolution,
        clip_has_audio=None if clip is None else clip.hasAudio,
    )


def _stored(row: LookupRow) -> StoredLookup:
    return StoredLookup(
        id=row.id,
        subject=row.subject,
        client_lookup_id=row.client_lookup_id or "",
        raw_selection=row.raw_selection,
        kind=Kind(row.kind),
        normalised_lemma=row.normalised_lemma,
        status=LookupStatus(row.status),
        senses=tuple(_sense(sense) for sense in row.senses),
        notice=row.notice,
        created_at=row.created_at,
        account_id=row.account_id,
        generation_job_ids=tuple(job.job_id for job in row.generation_jobs),
        allowance=_allowance(row),
    )


def _sense(row: LookupSenseRow) -> Sense:
    clip: Clip | None = None
    if row.clip_url is not None:
        clip = Clip(
            url=row.clip_url,
            durationSeconds=row.clip_duration_seconds or 0.0,
            resolution=cast('Literal["360p"]', row.clip_resolution),
            hasAudio=bool(row.clip_has_audio),
        )
    return Sense(
        senseLabel=row.sense_label,
        partOfSpeech=PartOfSpeech(row.part_of_speech),
        glossPhrase=row.gloss_phrase,
        entryId=row.entry_id,
        clip=clip,
    )


def _allowance(row: LookupRow) -> Allowance | None:
    if row.allowance_used is None or row.allowance_limit is None:
        return None
    return Allowance(
        used=row.allowance_used,
        limit=row.allowance_limit,
        periodEnd=row.allowance_period_end or "",
    )


def _unavailable() -> LookupUnavailableError:
    return LookupUnavailableError("The lookup record store is unavailable.")

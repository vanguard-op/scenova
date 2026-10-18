"""Relational store tests for lookup records (schema.md "Lookup").

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: a lookup survives the request
that made it, its idempotency key resolves a retry, and a deleted reader's
selection is stripped from the record while its outcome survives as a count
(C-001, C-002; nfr.md "Privacy & Compliance").

The real tables are the platform's migration history (`infra/db/migrations`);
the tests build the same shape from the store's model metadata, so the queries
and the row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import UniqueConstraint, create_engine, event, text
from sqlalchemy.engine import Engine

from lookup.app.config import Settings
from lookup.app.db import Base, LookupJobRow, LookupRow, LookupSenseRow
from lookup.app.errors import LookupUnavailableError
from lookup.app.generation import (
    GenerationClient,
    GenerationJob,
    GenerationJobStatus,
    GenerationUnavailableError,
)
from lookup.app.inventory import build_default_inventory
from lookup.app.library import InMemoryLibrary
from lookup.app.models import (
    Allowance,
    Clip,
    CreateLookupRequest,
    Kind,
    LookupStatus,
    PartOfSpeech,
    Sense,
)
from lookup.app.service import GENERATION_UNAVAILABLE_NOTICE, LookupService
from lookup.app.store import ANONYMIZED_SUBJECT, PostgresLookupStore, StoredLookup
from lookup.tests.fakes import RecordingEntitlementClient, RecordingGenerationClient

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"


def _engine(tmp_path: Path, name: str = "lookups.db") -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    return engine


def _engine_referenced_by_the_pipeline(tmp_path: Path) -> Engine:
    """An engine that holds the pipeline's foreign key to a lookup.

    A generation job's row references the lookup it belongs to (schema
    "Relationships": GenerationJob -> Lookup), and the real table is the
    platform's migration history; the tests build the referencing table here so a
    lookup write is exercised against the constraint the pipeline depends on.
    SQLite only enforces it once asked to.
    """

    engine = create_engine(f"sqlite:///{tmp_path / 'referenced.db'}")

    @event.listens_for(engine, "connect")
    def _enforce_foreign_keys(dbapi_connection: Any, _record: Any) -> None:
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    with engine.begin() as connection:
        connection.execute(
            text(
                "CREATE TABLE generation_jobs ("
                "id TEXT PRIMARY KEY, "
                "lookup_id TEXT NOT NULL REFERENCES lookups (id) ON DELETE CASCADE"
                ")"
            )
        )
    return engine


def _recorded_jobs(engine: Engine) -> list[str]:
    with engine.connect() as connection:
        rows = connection.execute(text("SELECT id FROM generation_jobs")).all()
        return [row[0] for row in rows]


def _reference_job(engine: Engine, job_id: str, lookup_id: str) -> None:
    with engine.begin() as connection:
        connection.execute(
            text("INSERT INTO generation_jobs (id, lookup_id) VALUES (:id, :lookup_id)"),
            {"id": job_id, "lookup_id": lookup_id},
        )


@asynccontextmanager
async def _store(tmp_path: Path) -> AsyncIterator[PostgresLookupStore]:
    store = PostgresLookupStore(_engine(tmp_path))
    try:
        yield store
    finally:
        await store.aclose()


def _senses() -> tuple[Sense, ...]:
    return (
        Sense(
            senseLabel="arrive",
            partOfSpeech=PartOfSpeech.VERB,
            glossPhrase="to move toward a place",
            entryId="le_1",
            clip=Clip(
                url="https://cdn.example/clip_1.mp4",
                durationSeconds=3.0,
                resolution="360p",
                hasAudio=False,
            ),
        ),
        Sense(
            senseLabel="reach",
            partOfSpeech=PartOfSpeech.VERB,
            glossPhrase="to arrive at a place",
            entryId=None,
            clip=None,
        ),
    )


def _lookup(
    lookup_id: str = "lk_1",
    *,
    subject: str = "reader-1",
    client_id: str = "client-1",
    raw_selection: str = "coming",
    status: LookupStatus = LookupStatus.GENERATING,
    senses: tuple[Sense, ...] | None = None,
    generation_job_ids: tuple[str, ...] = ("job_1",),
    allowance: Allowance | None = None,
    account_id: str | None = None,
) -> StoredLookup:
    return StoredLookup(
        id=lookup_id,
        subject=subject,
        client_lookup_id=client_id,
        raw_selection=raw_selection,
        kind=Kind.WORD,
        normalised_lemma="come",
        status=status,
        senses=_senses() if senses is None else senses,
        notice=None,
        created_at="2026-10-13T00:00:00+00:00",
        account_id=account_id,
        generation_job_ids=generation_job_ids,
        allowance=allowance,
    )


def test_the_schema_holds_one_record_per_reader_and_idempotency_key() -> None:
    # schema.md "Lookup" and its relationships: the idempotency key is unique per
    # caller, and the senses and jobs hang off the lookup as child rows.
    unique_keys = {
        tuple(sorted(column.name for column in constraint.columns))
        for constraint in LookupRow.metadata.tables["lookups"].constraints
        if isinstance(constraint, UniqueConstraint)
    }
    assert ("client_lookup_id", "subject") in unique_keys
    assert {
        fk.parent.name for fk in LookupSenseRow.metadata.tables["lookup_senses"].foreign_keys
    } == {"lookup_id"}
    assert {
        fk.parent.name for fk in LookupJobRow.metadata.tables["lookup_generation_jobs"].foreign_keys
    } == {"lookup_id"}


@pytest.mark.asyncio
async def test_a_lookup_is_read_back_with_its_senses_jobs_and_allowance(tmp_path: Path) -> None:
    async with _store(tmp_path) as store:
        await store.add(
            _lookup(
                account_id="reader-1",
                allowance=Allowance(used=3, limit=20, periodEnd="2026-11-15T12:00:00+00:00"),
            )
        )

        stored = await store.get("lk_1")

    assert stored is not None
    assert stored.raw_selection == "coming"
    assert stored.kind is Kind.WORD
    assert stored.status is LookupStatus.GENERATING
    assert stored.account_id == "reader-1"
    assert stored.generation_job_ids == ("job_1",)
    assert [sense.senseLabel for sense in stored.senses] == ["arrive", "reach"]
    assert stored.senses[0].clip is not None
    assert stored.senses[0].clip.url == "https://cdn.example/clip_1.mp4"
    assert stored.senses[0].clip.durationSeconds == 3.0
    assert stored.senses[1].clip is None
    assert stored.allowance is not None
    assert stored.allowance.used == 3
    assert stored.allowance.limit == 20
    assert stored.allowance.periodEnd == "2026-11-15T12:00:00+00:00"


@pytest.mark.asyncio
async def test_a_lookup_without_an_allowance_reads_it_back_as_null(tmp_path: Path) -> None:
    # A reader who is not signed in is metered on the device and never carries an
    # allowance here (C-001).
    async with _store(tmp_path) as store:
        await store.add(_lookup())

        stored = await store.get("lk_1")

    assert stored is not None and stored.allowance is None


@pytest.mark.asyncio
async def test_an_idempotency_key_finds_the_lookup_it_made(tmp_path: Path) -> None:
    async with _store(tmp_path) as store:
        await store.add(_lookup())

        found = await store.find_by_client_id("reader-1", "client-1")
        other_reader = await store.find_by_client_id("reader-2", "client-1")

    assert found is not None and found.id == "lk_1"
    assert other_reader is None


@pytest.mark.asyncio
async def test_replacing_a_lookup_swaps_its_senses_and_jobs(tmp_path: Path) -> None:
    # A poll can replace a lookup whose clip arrived after it was first made, so
    # the record is written afresh rather than accumulating senses (C-002).
    async with _store(tmp_path) as store:
        await store.add(_lookup())
        await store.add(
            _lookup(
                status=LookupStatus.SERVED,
                senses=_senses()[:1],
                generation_job_ids=(),
                raw_selection="coming",
            )
        )

        stored = await store.get("lk_1")

    assert stored is not None
    assert stored.status is LookupStatus.SERVED
    assert [sense.senseLabel for sense in stored.senses] == ["arrive"]
    assert stored.generation_job_ids == ()


@pytest.mark.asyncio
async def test_anonymizing_a_reader_strips_their_selection_and_keeps_the_count(
    tmp_path: Path,
) -> None:
    async with _store(tmp_path) as store:
        await store.add(
            _lookup(
                "lk_1",
                account_id="reader-1",
                allowance=Allowance(used=1, limit=20, periodEnd="p"),
            )
        )
        await store.add(_lookup("lk_2", client_id="client-2", raw_selection="bank"))
        await store.add(_lookup("lk_3", subject="reader-2", client_id="client-3"))

        anonymized = await store.anonymize_subject("reader-1")

        first = await store.get("lk_1")
        untouched = await store.get("lk_3")
        key = await store.find_by_client_id("reader-1", "client-1")
        again = await store.anonymize_subject("reader-1")

    assert anonymized == 2
    assert first is not None
    assert first.subject == ANONYMIZED_SUBJECT
    assert first.account_id is None, "the account that made the lookup goes with the deletion"
    assert first.raw_selection == ""
    assert first.normalised_lemma is None
    assert first.senses == ()
    assert first.status is LookupStatus.GENERATING, "the outcome survives the deletion"
    assert first.created_at == "2026-10-13T00:00:00+00:00"
    assert first.allowance is not None and first.allowance.used == 1
    assert key is None, "the idempotency key goes with the reader who held it"
    assert untouched is not None and untouched.subject == "reader-2"
    assert again == 0, "a re-run for an already anonymized reader finds nothing"


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_unavailable() -> None:
    store = PostgresLookupStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(LookupUnavailableError):
            await store.add(_lookup())
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_a_lookup_made_through_the_service_is_durable(tmp_path: Path) -> None:
    # The relational store is wired behind the same port, so a lookup recorded on
    # the create path is the one the poll reads back (C-001, C-002).
    service = LookupService(
        inventory=build_default_inventory(),
        store=PostgresLookupStore(_engine(tmp_path, "service.db")),
        library=InMemoryLibrary(),
        generation=RecordingGenerationClient(),
        entitlement=RecordingEntitlementClient(),
    )
    request = CreateLookupRequest(
        selection="coming",
        clientLookupId="client-1",
        platform="android",
        locale="en",
        consentModelProcessing=True,
        subject="reader-1",
    )
    try:
        created = await service.create_lookup(request, "corr")
        polled = await service.get_lookup(created.lookupId, "reader-1", "corr")
    finally:
        await service.aclose()

    assert polled.lookupId == created.lookupId
    assert polled.rawSelection == "coming"
    assert polled.normalisedLemma == "come"


def _service_over(store: PostgresLookupStore, generation: GenerationClient) -> LookupService:
    return LookupService(
        inventory=build_default_inventory(),
        store=store,
        library=InMemoryLibrary(),
        generation=generation,
        entitlement=RecordingEntitlementClient(),
    )


def _request(selection: str = "coming") -> CreateLookupRequest:
    return CreateLookupRequest(
        selection=selection,
        clientLookupId="client-1",
        platform="android",
        locale="en",
        consentModelProcessing=True,
        subject="reader-1",
    )


class _StoreObservingGeneration:
    """A generation client that reads the lookup back as the job arrives.

    The pipeline's job row holds a foreign key to the lookup it names, so a job
    can only be accepted once that lookup is recorded; this observes the record at
    the moment of the hand-off, which is where an ordering slip shows.
    """

    def __init__(self, store: PostgresLookupStore) -> None:
        self._store = store
        self.jobs: list[GenerationJob] = []
        self.recorded: list[bool] = []

    async def enqueue(self, job: GenerationJob) -> None:
        self.recorded.append(await self._store.get(job.lookup_id) is not None)
        self.jobs.append(job)

    async def status(self, job_id: str) -> GenerationJobStatus:
        return GenerationJobStatus.QUEUED

    async def aclose(self) -> None:
        return None


@pytest.mark.asyncio
async def test_a_lookup_is_recorded_before_its_generation_job_is_handed_over(
    tmp_path: Path,
) -> None:
    # A generation job names the lookup it belongs to, and the pipeline's row
    # holds a foreign key to it (schema "Relationships": GenerationJob -> Lookup);
    # a job handed over before its lookup is durable names a lookup the database
    # does not hold, and the pipeline refuses it.
    store = PostgresLookupStore(_engine(tmp_path, "before-enqueue.db"))
    generation = _StoreObservingGeneration(store)
    service = _service_over(store, generation)
    try:
        created = await service.create_lookup(_request(), "corr")
    finally:
        await service.aclose()

    assert created.status is LookupStatus.GENERATING
    assert [job.lookup_id for job in generation.jobs] == [created.lookupId]
    assert generation.recorded == [True]


@pytest.mark.asyncio
async def test_a_lookup_whose_job_was_refused_is_recorded_as_the_fallback(
    tmp_path: Path,
) -> None:
    # The pipeline would not accept the job, so the durable record must not claim
    # a generation: a poll of it would otherwise wait for a clip that no job will
    # produce (C-003, FEAT-005).
    store = PostgresLookupStore(_engine(tmp_path, "refused.db"))
    service = _service_over(
        store, RecordingGenerationClient(error=GenerationUnavailableError("unreachable"))
    )
    try:
        created = await service.create_lookup(_request(), "corr")
        stored = await store.get(created.lookupId)
    finally:
        await service.aclose()

    assert created.status is LookupStatus.FALLBACK
    assert created.notice == GENERATION_UNAVAILABLE_NOTICE
    assert stored is not None
    assert stored.status is LookupStatus.FALLBACK
    assert stored.generation_job_ids == ()
    assert stored.senses[0].clip is None


@pytest.mark.asyncio
async def test_replacing_a_lookup_keeps_the_generation_job_that_names_it(
    tmp_path: Path,
) -> None:
    # A poll replaces the record when the clip arrives. Rows that reference the
    # lookup — the pipeline's generation jobs, the reader's feedback, reports,
    # push registration, and saved history (schema "Relationships") — are not the
    # record's to take with it, so the write updates the record rather than
    # deleting and re-inserting it.
    engine = _engine_referenced_by_the_pipeline(tmp_path)
    store = PostgresLookupStore(engine)
    try:
        await store.add(_lookup())
        _reference_job(engine, "job_1", "lk_1")

        await store.add(
            _lookup(status=LookupStatus.SERVED, senses=_senses()[:1], generation_job_ids=())
        )
        jobs = _recorded_jobs(engine)
        stored = await store.get("lk_1")
    finally:
        await store.aclose()

    assert jobs == ["job_1"], "the generation that names the lookup survives the replace"
    assert stored is not None
    assert stored.status is LookupStatus.SERVED
    assert [sense.senseLabel for sense in stored.senses] == ["arrive"]


@pytest.mark.asyncio
async def test_a_lookup_that_cannot_be_recorded_is_unavailable(tmp_path: Path) -> None:
    service = LookupService(
        inventory=build_default_inventory(),
        store=PostgresLookupStore(create_engine(_UNREACHABLE)),
        library=InMemoryLibrary(),
        generation=RecordingGenerationClient(),
        entitlement=RecordingEntitlementClient(),
    )
    request = CreateLookupRequest(
        selection="coming",
        clientLookupId="client-1",
        platform="android",
        locale="en",
        consentModelProcessing=True,
        subject="reader-1",
    )
    try:
        with pytest.raises(LookupUnavailableError):
            await service.create_lookup(request, "corr")
    finally:
        await service.aclose()


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None

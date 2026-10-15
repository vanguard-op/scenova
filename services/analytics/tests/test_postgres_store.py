"""Relational event-store tests: the intake's durability and governance passes
(C-007; `analytics.md` "Analytics Data Governance").

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: an accepted event is stored
once however many times the batch is retried, the store survives the process
that wrote it, a deleted reader's identity is severed while the event stays as
a count, and the retention pass aggregates and drops what passed the window
(schema.md "Event Intake"; architecture.md "Analytics / Event Tracking": the
event store is the primary database).

The real table is the platform's migration history (`infra/db/migrations`): the
tests build the same shape from the store's model metadata, so the queries and
the row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from analytics.app.config import Settings
from analytics.app.db import Base
from analytics.app.errors import EventStoreUnavailableError
from analytics.app.models import EventIn, IngestRequest
from analytics.app.store import (
    ANONYMIZED_USER_ID,
    InMemoryEventStore,
    PostgresEventStore,
    StoredEvent,
    build_default_store,
)
from analytics.app.taxonomy import EventName

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"

_NOW = datetime(2026, 10, 14, 12, 0, 0, tzinfo=UTC)


def _engine(tmp_path: Path, name: str) -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    return engine


def _stored(
    event_id: str,
    name: EventName = EventName.LOOKUP_STARTED,
    received_at: datetime = _NOW,
    *,
    user_id: str = "reader-1",
    properties: dict[str, str | int | None] | None = None,
    consent_gated: bool = False,
) -> StoredEvent:
    return StoredEvent(
        event_id=event_id,
        name=name,
        occurred_at=received_at,
        user_id=user_id,
        anonymous_id="anon-1",
        session_id="sess-1",
        platform="android",
        app_version="1.0.0+1",
        locale="en",
        properties=properties or {},
        received_at=received_at,
        consent_gated=consent_gated,
    )


@asynccontextmanager
async def _store(engine: Engine) -> AsyncIterator[PostgresEventStore]:
    store = PostgresEventStore(engine)
    try:
        yield store
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_an_accepted_event_is_stored_and_survives_a_restart(tmp_path: Path) -> None:
    # The intake writes each accepted event to the primary database before it
    # acknowledges it, so the event survives a restart of the intake.
    engine = _engine(tmp_path, "durable.db")
    async with _store(engine) as first:
        assert await first.append(_stored("evt-1")) is True
        assert await first.count() == 1

    # The intake comes back as a new process over the same database.
    async with _store(engine) as second:
        assert await second.count() == 1
        stored = await second.get("evt-1")

    assert stored is not None
    assert stored.name is EventName.LOOKUP_STARTED
    assert stored.user_id == "reader-1"
    assert stored.received_at == _NOW
    assert stored.consent_gated is False


@pytest.mark.asyncio
async def test_a_retried_batch_is_stored_once(tmp_path: Path) -> None:
    # The client queues and re-sends offline batches; the `event_id` key makes
    # the retry idempotent, so a second batch appends nothing.
    engine = _engine(tmp_path, "idempotent.db")
    async with _store(engine) as store:
        assert await store.append(_stored("evt-1")) is True
        assert await store.append(_stored("evt-1")) is False

        assert await store.count() == 1


@pytest.mark.asyncio
async def test_an_event_round_trips_its_taxonomy_properties(tmp_path: Path) -> None:
    engine = _engine(tmp_path, "properties.db")
    async with _store(engine) as store:
        await store.append(_stored("evt-1", properties={"kind": "word", "source": "typed"}))

        stored = await store.get("evt-1")

    assert stored is not None
    assert stored.properties == {"kind": "word", "source": "typed"}


@pytest.mark.asyncio
async def test_anonymizing_a_reader_severs_the_identity_but_keeps_the_event(
    tmp_path: Path,
) -> None:
    # A data-subject deletion removes or anonymizes the reader's events across
    # the event store: the identity goes, the event stays so the counts are
    # unaffected, and the device and session identifiers go with it.
    engine = _engine(tmp_path, "anonymize.db")
    async with _store(engine) as store:
        await store.append(_stored("evt-1", user_id="reader-1"))
        await store.append(_stored("evt-2", user_id="reader-2"))

        anonymized = await store.anonymize_subject("reader-1")
        again = await store.anonymize_subject("reader-1")

        severed = await store.get("evt-1")
        untouched = await store.get("evt-2")

    assert anonymized == 1
    assert again == 0, "a re-run finds no event under the original identity"
    assert severed is not None
    assert severed.user_id == ANONYMIZED_USER_ID
    assert severed.anonymous_id == ""
    assert severed.session_id == ""
    assert untouched is not None and untouched.user_id == "reader-2"


@pytest.mark.asyncio
async def test_the_retention_pass_aggregates_and_drops_the_expired_by_name(
    tmp_path: Path,
) -> None:
    # Raw events are kept for fourteen months and then aggregated or dropped;
    # the counts are what survive the pass, keyed by event name.
    engine = _engine(tmp_path, "retention.db")
    old = datetime(2025, 5, 1, 12, 0, 0, tzinfo=UTC)
    async with _store(engine) as store:
        await store.append(_stored("evt-1", EventName.APP_OPENED, old))
        await store.append(_stored("evt-2", EventName.APP_OPENED, old))
        await store.append(_stored("evt-3", EventName.LOOKUP_SERVED, old))
        await store.append(_stored("evt-4", EventName.LOOKUP_SERVED, _NOW))

        aggregated = await store.purge_before(datetime(2026, 1, 1, tzinfo=UTC))

        remaining = await store.all()
        counts = await store.count()

    assert aggregated == {"app_opened": 2, "lookup_served": 1}
    assert [event.event_id for event in remaining] == ["evt-4"]
    assert counts == 1


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_the_store_being_unavailable() -> None:
    store = PostgresEventStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(EventStoreUnavailableError):
            await store.append(_stored("evt-1"))
        with pytest.raises(EventStoreUnavailableError):
            await store.get("evt-1")
        with pytest.raises(EventStoreUnavailableError):
            await store.count()
        with pytest.raises(EventStoreUnavailableError):
            await store.anonymize_subject("reader-1")
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_an_unavailable_store_refuses_the_batch_so_the_client_retries() -> None:
    # The intake writes each event to the store before it acknowledges the
    # batch; a store it cannot reach is answered as retryable, never as
    # accepted, and the `event_id` key makes the client's re-send idempotent.
    from analytics.app.service import EventService

    service = EventService(
        store=PostgresEventStore(create_engine(_UNREACHABLE)),
        settings=Settings(),
    )
    with pytest.raises(EventStoreUnavailableError):
        await service.ingest(_batch("evt-1"), "reader-1")


def _batch(event_id: str) -> IngestRequest:
    return IngestRequest(
        events=[
            EventIn(
                eventId=event_id,
                name="lookup_started",
                occurredAt="2026-10-13T12:00:00Z",
                anonymousId="anon-1",
                sessionId="sess-1",
                platform="android",
                appVersion="1.0.0+1",
                locale="en",
                properties={"kind": "word", "source": "typed"},
            )
        ]
    )


@pytest.mark.asyncio
async def test_the_batch_intake_is_writethrough_on_the_relational_store(
    tmp_path: Path,
) -> None:
    # The service path, not only the store: a batch the intake accepted is in
    # the relational store before the response is out.
    engine = _engine(tmp_path, "writethrough.db")
    from analytics.app.service import EventService

    service = EventService(store=PostgresEventStore(engine), settings=Settings())
    response = await service.ingest(_batch("evt-1"), "reader-1")

    assert response.accepted == 1
    async with _store(engine) as reopened:
        assert await reopened.count() == 1


def test_the_store_the_environment_selects() -> None:
    # A configured `DATABASE_URL` resolves the primary relational store; an
    # empty environment resolves the in-memory store the tests and a bare local
    # run use.
    assert isinstance(build_default_store("sqlite:///choice.db"), PostgresEventStore)
    assert isinstance(build_default_store(None), InMemoryEventStore)

    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None

"""Relational push-store tests: registrations and pending notices in the
primary database (C-008, FEAT-008).

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: a registration and a queued
notice survive the service process that made them, a retried clip-ready ingest
never sends a second notice, a delivered notice is removed so the queue holds
only what is undelivered, and an unreachable database is reported as the store
being unavailable rather than swallowed (schema.md "PushRegistration",
"PendingNotice"; architecture.md "Notification Service").

The real tables are the platform's migration history (`infra/db/migrations`):
the tests build the same shape from the store's model metadata, so the queries
and the row mapping are exercised without a database server.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from sqlalchemy import UniqueConstraint, create_engine
from sqlalchemy.engine import Engine

from notification.app.config import Settings
from notification.app.db import Base
from notification.app.errors import PushStoreUnavailableError
from notification.app.lookups import LookupStatus
from notification.app.models import ClipReadyRequest, Platform, RegisterRequest
from notification.app.service import NotificationService
from notification.app.store import (
    InMemoryNoticeQueue,
    InMemoryRegistrationStore,
    PostgresPushStore,
    PushRegistration,
    QueuedNotice,
    build_default_store,
)
from notification.tests.fakes import (
    SUBJECT,
    FakeLookupDirectory,
    FakePushSender,
    clip_descriptor,
    register_body,
)

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"


def _engine(tmp_path: Path, name: str) -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    return engine


def _registration(
    lookup_id: str = "lk_1", subject: str = SUBJECT, token: str = "fcm-token-1"
) -> PushRegistration:
    return PushRegistration(
        token=token, platform=Platform.ANDROID, subject=subject, lookup_id=lookup_id
    )


def _queued(notice_id: str, lookup_id: str = "lk_1", token: str = "fcm-token-1") -> QueuedNotice:
    return QueuedNotice(
        id=notice_id,
        lookup_id=lookup_id,
        token=token,
        platform=Platform.ANDROID,
        clip_url="https://cdn.example/clip_1.mp4",
        duration_seconds=3.0,
        resolution="360p",
        has_audio=False,
    )


def _clip_ready(lookup_id: str = "lk_1", job_id: str = "job_1") -> ClipReadyRequest:
    return ClipReadyRequest.model_validate(
        {
            "lookupId": lookup_id,
            "jobId": job_id,
            "clip": clip_descriptor(),
        }
    )


def _register_request() -> RegisterRequest:
    return RegisterRequest.model_validate(register_body())


def _service(
    engine: Engine,
    sender: FakePushSender,
    *,
    generating: bool = True,
) -> NotificationService:
    store = PostgresPushStore(engine)
    statuses = {("lk_1", SUBJECT): LookupStatus.GENERATING} if generating else {}
    return NotificationService(
        store=store,
        queue=store,
        lookups=FakeLookupDirectory(statuses),
        sender=sender,
    )


def test_the_schema_deduplicates_a_device_per_lookup() -> None:
    # schema.md "PushRegistration": keyed by lookup, one row per device, so a
    # reader who registers twice is still one device to notify (C-008).
    def unique_keys(table_name: str) -> set[tuple[str, ...]]:
        return {
            tuple(sorted(column.name for column in constraint.columns))
            for constraint in Base.metadata.tables[table_name].constraints
            if isinstance(constraint, UniqueConstraint)
        }

    assert ("device_token", "lookup_id", "platform") in unique_keys("push_registrations")


@pytest.mark.asyncio
async def test_a_registration_survives_a_restart_of_the_service(tmp_path: Path) -> None:
    # The registration is durable: a service that comes back after the reader
    # registered still knows the device to notify (architecture.md
    # "Notification Service").
    engine = _engine(tmp_path, "registrations.db")
    first = PostgresPushStore(engine)
    await first.add(_registration())

    second = PostgresPushStore(engine)
    consumed = await second.consume("lk_1")

    await first.aclose()
    await second.aclose()
    assert [(device.token, device.platform) for device in consumed] == [
        ("fcm-token-1", Platform.ANDROID)
    ]


@pytest.mark.asyncio
async def test_a_consumed_lookup_is_never_consumed_again(tmp_path: Path) -> None:
    # The consumption and the dedupe are the same rows: the clip-ready ingest
    # that took the registrations leaves nothing for a retried ingest to send a
    # second notice with.
    engine = _engine(tmp_path, "once.db")
    store = PostgresPushStore(engine)
    try:
        await store.add(_registration())

        first = await store.consume("lk_1")
        second = await store.consume("lk_1")
    finally:
        await store.aclose()

    assert len(first) == 1
    assert second == []


@pytest.mark.asyncio
async def test_a_repeated_device_registration_is_held_once(tmp_path: Path) -> None:
    engine = _engine(tmp_path, "dedupe.db")
    store = PostgresPushStore(engine)
    try:
        await store.add(_registration())
        await store.add(_registration())

        consumed = await store.consume("lk_1")
    finally:
        await store.aclose()

    assert len(consumed) == 1


@pytest.mark.asyncio
async def test_a_queued_notice_survives_a_restart_and_drains_oldest_first(
    tmp_path: Path,
) -> None:
    # A push outage holds the notice in the primary database, so a restart
    # delays delivery rather than losing it, and the drain resumes the queued
    # payload in order.
    engine = _engine(tmp_path, "queue.db")
    first = PostgresPushStore(engine)
    held = await first.enqueue([_queued("pn_a"), _queued("pn_b", token="fcm-token-2")])

    second = PostgresPushStore(engine)
    await second.mark_delivered([held[0].id])
    outstanding = await second.outstanding()

    await first.aclose()
    await second.aclose()

    assert [notice.id for notice in outstanding] == [held[1].id]
    assert outstanding[0].clip_url == "https://cdn.example/clip_1.mp4"
    assert outstanding[0].duration_seconds == 3.0
    assert outstanding[0].resolution == "360p"
    assert outstanding[0].has_audio is False


@pytest.mark.asyncio
async def test_waiting_on_a_lookup_the_service_cannot_confirm_holds_nothing(
    tmp_path: Path,
) -> None:
    # A registration for a lookup the directory cannot confirm is not held: the
    # store write never happens, so a restart finds no half-done association.
    engine = _engine(tmp_path, "unconfirmed.db")
    store = PostgresPushStore(engine)
    directory = FakeLookupDirectory({}, unavailable=True)
    service = NotificationService(
        store=store, queue=store, lookups=directory, sender=FakePushSender()
    )
    try:
        response = await service.register(_register_request(), SUBJECT)
        consumed_later = await PostgresPushStore(engine).consume("lk_1")
    finally:
        await service.aclose()

    assert response.registered is False
    assert consumed_later == []


@pytest.mark.asyncio
async def test_the_queue_bound_drops_the_oldest_notice(tmp_path: Path) -> None:
    # A long outage cannot grow the queue without limit; the oldest is dropped
    # so the drain stays in order.
    engine = _engine(tmp_path, "bound.db")
    store = PostgresPushStore(engine, pending_limit=2)
    try:
        await store.enqueue([_queued("pn_a")])
        await store.enqueue([_queued("pn_b")])
        held = await store.enqueue([_queued("pn_c")])

        outstanding = await store.outstanding()
    finally:
        await store.aclose()

    assert [notice.id for notice in held] == ["pn_c"]
    assert [notice.id for notice in outstanding] == ["pn_b", "pn_c"]


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_the_store_being_unavailable() -> None:
    store = PostgresPushStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(PushStoreUnavailableError):
            await store.add(_registration())
        with pytest.raises(PushStoreUnavailableError):
            await store.consume("lk_1")
        with pytest.raises(PushStoreUnavailableError):
            await store.enqueue([_queued("pn_a")])
        with pytest.raises(PushStoreUnavailableError):
            await store.outstanding()
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_the_register_intake_answers_retryable_when_the_store_is_down() -> None:
    # The registration the reader made is a claim the service can only honour
    # through its store, so an unavailable store is answered as retryable
    # rather than as a registration that will not be held.
    service = _service(create_engine(_UNREACHABLE), FakePushSender())
    try:
        with pytest.raises(PushStoreUnavailableError):
            await service.register(_register_request(), SUBJECT)
    finally:
        await service.aclose()


@pytest.mark.asyncio
async def test_a_clip_ready_ingest_after_a_restart_still_reaches_the_device(
    tmp_path: Path,
) -> None:
    engine = _engine(tmp_path, "restart.db")
    registering = _service(engine, FakePushSender())
    try:
        await registering.register(_register_request(), SUBJECT)
    finally:
        await registering.aclose()

    sender = FakePushSender()
    restarted = _service(engine, sender)
    try:
        response = await restarted.clip_ready(_clip_ready())
    finally:
        await restarted.aclose()

    assert response.queued == 1
    assert [(token, notice.lookup_id) for token, _, notice in sender.sent] == [
        ("fcm-token-1", "lk_1")
    ]


@pytest.mark.asyncio
async def test_a_push_outage_after_a_restart_holds_the_notice_for_the_drain(
    tmp_path: Path,
) -> None:
    engine = _engine(tmp_path, "outage.db")
    registering = _service(engine, FakePushSender())
    try:
        await registering.register(_register_request(), SUBJECT)
    finally:
        await registering.aclose()

    down_sender = FakePushSender(unavailable=True)
    restarted_down = _service(engine, down_sender)
    try:
        response = await restarted_down.clip_ready(_clip_ready())
        assert response.queued == 1
        assert down_sender.sent == []
    finally:
        await restarted_down.aclose()

    back_sender = FakePushSender()
    back = _service(engine, back_sender)
    try:
        delivered = await back.drain_pending()
        outstanding = await PostgresPushStore(engine).outstanding()
    finally:
        await back.aclose()

    assert delivered == 1
    assert outstanding == []
    assert [(token, notice.lookup_id) for token, _, notice in back_sender.sent] == [
        ("fcm-token-1", "lk_1")
    ]


@pytest.mark.asyncio
async def test_an_ingest_with_no_registrations_holds_nothing(tmp_path: Path) -> None:
    engine = _engine(tmp_path, "empty.db")
    store = PostgresPushStore(engine)
    try:
        held = await store.enqueue([])

        outstanding = await store.outstanding()
    finally:
        await store.aclose()

    assert held == []
    assert outstanding == []


@pytest.mark.asyncio
async def test_the_default_store_is_relational_when_a_database_is_configured(
    tmp_path: Path,
) -> None:
    store, queue = build_default_store(f"sqlite:///{tmp_path / 'service.db'}")
    assert isinstance(store, PostgresPushStore)
    assert queue is store

    memory_store, memory_queue = build_default_store(None)
    assert isinstance(memory_store, InMemoryRegistrationStore)
    assert isinstance(memory_queue, InMemoryNoticeQueue)
    await memory_store.aclose()
    await memory_queue.aclose()
    await store.aclose()


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None

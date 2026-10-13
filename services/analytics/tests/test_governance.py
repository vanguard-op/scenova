"""Governance tests (`analytics.md` "Analytics Data Governance").

Consent gating, the fourteen-month retention, deletion propagation, and the
no-sampling-at-launch rule, exercised against the store the intake writes to.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from analytics.app.config import Settings
from analytics.app.service import EventService
from analytics.app.store import InMemoryEventStore, StoredEvent, months_ago, retention_cutoff
from analytics.app.taxonomy import EventName
from analytics.tests.fakes import batch, event

_NOW = datetime(2026, 10, 13, tzinfo=UTC)


def _service(
    settings: Settings | None = None, now: datetime = _NOW
) -> tuple[EventService, InMemoryEventStore]:
    store = InMemoryEventStore()
    service = EventService(store=store, settings=settings or Settings(), clock=lambda: now)
    return service, store


def _stored(
    event_id: str, name: EventName, received_at: datetime, *, user_id: str = "reader-1"
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
        properties={},
        received_at=received_at,
        consent_gated=name in {EventName.LOOKUP_STARTED, EventName.CLIP_PLAYED},
    )


@pytest.mark.asyncio
async def test_the_token_subject_is_the_pseudonymous_user_id() -> None:
    service, store = _service()
    await service.ingest(batch(event()), "reader-9")
    stored = await store.all()
    assert [item.user_id for item in stored] == ["reader-9"]


@pytest.mark.asyncio
async def test_a_withdrawn_subject_has_gated_events_suppressed() -> None:
    service, store = _service()
    result = await service.ingest(
        batch(
            event(eventId="e1", name="consent_changed", properties={"consent": False}),
            event(eventId="e2", name="lookup_started", properties={"kind": "word"}),
            event(eventId="e3", name="app_opened", properties={"source": "resume"}),
        ),
        "reader-1",
    )
    assert result.accepted == 2
    names = [item.name for item in await store.all()]
    assert EventName.LOOKUP_STARTED not in names
    assert EventName.APP_OPENED in names


@pytest.mark.asyncio
async def test_granted_consent_keeps_gated_events() -> None:
    service, store = _service()
    result = await service.ingest(
        batch(
            event(eventId="e1", name="consent_changed", properties={"consent": True}),
            event(eventId="e2", name="history_viewed", properties={"item_count": 2}),
        ),
        "reader-1",
    )
    assert result.accepted == 2
    assert await store.count() == 2


@pytest.mark.asyncio
async def test_an_unknown_subject_is_allowed_through() -> None:
    # Consent is the account's, and the client suppresses reading-behaviour
    # events until it is granted (C-007); the intake cannot know better.
    service, _ = _service()
    result = await service.ingest(
        batch(event(name="clip_played", properties={"entry_id": "le_1"})), "reader-1"
    )
    assert result.accepted == 1


@pytest.mark.asyncio
async def test_retention_aggregates_then_drops_events_past_the_window() -> None:
    service, store = _service()
    old = months_ago(_NOW, 15)
    recent = months_ago(_NOW, 1)
    await store.append(_stored("e1", EventName.APP_OPENED, old))
    await store.append(_stored("e2", EventName.APP_OPENED, old))
    await store.append(_stored("e3", EventName.LOOKUP_SERVED, recent))

    aggregated = await service.purge_expired()

    assert aggregated == {"app_opened": 2}
    remaining = await store.all()
    assert [item.event_id for item in remaining] == ["e3"]


@pytest.mark.asyncio
async def test_deletion_propagation_removes_the_subjects_events() -> None:
    service, store = _service()
    await store.append(_stored("e1", EventName.APP_OPENED, _NOW, user_id="reader-1"))
    await store.append(_stored("e2", EventName.APP_OPENED, _NOW, user_id="reader-2"))

    removed = await service.delete_subject("reader-1")

    assert removed == 1
    remaining = await store.all()
    assert [item.event_id for item in remaining] == ["e2"]


@pytest.mark.asyncio
async def test_a_retried_event_is_stored_once() -> None:
    service, store = _service()
    first = await service.ingest(batch(event()), "reader-1")
    second = await service.ingest(batch(event()), "reader-1")
    assert first.accepted == 1
    assert second.accepted == 0
    assert await store.count() == 1


@pytest.mark.asyncio
async def test_no_sampling_at_launch_keeps_every_event() -> None:
    service, store = _service()
    assert service.sample_rate == 1.0
    events = [event(eventId=f"evt-{index}") for index in range(10)]
    result = await service.ingest(batch(*events), "reader-1")
    assert result.accepted == 10
    assert await store.count() == 10


@pytest.mark.asyncio
async def test_a_stated_sample_rate_is_applied() -> None:
    service, store = _service(Settings(sample_rate=0.0))
    result = await service.ingest(batch(event()), "reader-1")
    assert result.accepted == 0
    assert await store.count() == 0


@pytest.mark.asyncio
async def test_a_half_sample_rate_keeps_a_deterministic_share() -> None:
    service, _ = _service(Settings(sample_rate=0.5))
    events = [event(eventId=f"evt-{index}") for index in range(50)]
    first = await service.ingest(batch(*events), "reader-1")
    assert 0 < first.accepted < 50


def test_months_ago_uses_calendar_months() -> None:
    assert months_ago(_NOW, 14) == datetime(2025, 8, 13, tzinfo=UTC)
    # A month end clamps to the shorter month rather than overflowing.
    assert months_ago(datetime(2026, 3, 31, tzinfo=UTC), 14) == datetime(2025, 1, 31, tzinfo=UTC)


def test_retention_cutoff_is_fourteen_months_before_now() -> None:
    assert retention_cutoff(_NOW, 14) == datetime(2025, 8, 13, tzinfo=UTC)

"""Tests for the event anonymization seam (FEAT-013; analytics.md "Analytics Data
Governance").

A reader's account deletion anonymizes their events across the event store, not
only the primary database. The seam is internal, never reachable from the reader
client, and idempotent so a re-run is safe.
"""

from __future__ import annotations

import pytest

from analytics.app.config import Settings
from analytics.app.service import EventService
from analytics.app.store import ANONYMIZED_USER_ID, InMemoryEventStore
from analytics.tests.fakes import AUTH, batch, event, make_client

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _rig() -> tuple[EventService, InMemoryEventStore]:
    store = InMemoryEventStore()
    return EventService(store=store, settings=Settings()), store


@pytest.mark.asyncio
async def test_the_seam_anonymizes_the_readers_events() -> None:
    service, store = _rig()
    with make_client(service=service) as client:
        client.post("/v1/events", json={"events": [event()]}, headers=AUTH)
        response = client.post(
            "/internal/events/anonymize", json={"subject": "reader-1"}, headers=_INTERNAL
        )

    assert response.status_code == 200
    assert response.json() == {"anonymized": 1}
    stored = (await store.all())[0]
    assert stored.user_id == ANONYMIZED_USER_ID


def test_the_seam_requires_an_internal_identity() -> None:
    with make_client() as client:
        response = client.post("/internal/events/anonymize", json={"subject": "reader-1"})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


@pytest.mark.asyncio
async def test_a_re_run_anonymizes_nothing_more() -> None:
    service, store = _rig()
    with make_client(service=service) as client:
        client.post("/v1/events", json={"events": [event()]}, headers=AUTH)
        first = client.post(
            "/internal/events/anonymize", json={"subject": "reader-1"}, headers=_INTERNAL
        )
        second = client.post(
            "/internal/events/anonymize", json={"subject": "reader-1"}, headers=_INTERNAL
        )

    assert first.json() == {"anonymized": 1}
    assert second.json() == {"anonymized": 0}
    assert (await store.all())[0].user_id == ANONYMIZED_USER_ID


@pytest.mark.asyncio
async def test_the_anonymization_forgets_the_recorded_consent() -> None:
    # The intake also holds the subject's recorded consent; a deletion drops it
    # with the events, so no state keyed by the reader is left behind.
    service, _ = _rig()
    await service.ingest(
        batch(event(eventId="e1", name="consent_changed", properties={"consent": False})),
        "reader-1",
    )
    await service.anonymize_subject("reader-1")

    result = await service.ingest(
        batch(event(eventId="e2", name="lookup_started", properties={"kind": "word"})), "reader-1"
    )

    assert result.accepted == 1


@pytest.mark.asyncio
async def test_another_subject_is_left_alone() -> None:
    # The seam is addressed by the token subject the intake stored, so a
    # different subject changes nothing.
    service, store = _rig()
    with make_client(service=service) as client:
        client.post("/v1/events", json={"events": [event()]}, headers=AUTH)
        response = client.post(
            "/internal/events/anonymize", json={"subject": "reader-9"}, headers=_INTERNAL
        )

    assert response.json() == {"anonymized": 0}
    assert (await store.all())[0].user_id == "reader-1"

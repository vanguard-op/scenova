"""Acceptance tests for the product event intake through the shipped gateway.

Verifies C-007 (`POST /v1/events`) against the trust-and-continuity events the
phase emits — EVT-010 `clip_played`, EVT-011 `clip_feedback_given`, EVT-012
`clip_reported`, EVT-013 `history_viewed`, EVT-014 `history_replayed`, and EVT-015
`history_entry_removed` (`analytics.md` "Event Taxonomy"). The gateway routes the
batch to the analytics intake, which validates it against the taxonomy and the
personal-data rule and stores it.

The stack boots the analytics service on the client path, so a batch reaches a real
intake rather than an absent port.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

_OCCURRED_AT = "2026-10-15T12:00:00+00:00"


def _auth(subject: str = "reader-1") -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _event(name: str, properties: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "eventId": f"evt-{uuid4().hex}",
        "name": name,
        "occurredAt": _OCCURRED_AT,
        "anonymousId": "anon-1",
        "sessionId": "session-1",
        "platform": "android",
        "appVersion": "1.0.0",
        "locale": "en",
        "properties": properties or {},
    }


def _ingest(
    gateway: httpx2.Client, events: list[dict[str, Any]], *, subject: str = "reader-1"
) -> httpx2.Response:
    return gateway.post("/v1/events", headers=_auth(subject), json={"events": events})


def test_the_trust_and_continuity_events_are_accepted(gateway: httpx2.Client) -> None:
    # The phase's events, each with its taxonomy key properties, are accepted
    # through the shipped intake (C-007 202 `accepted`).
    events = [
        _event("clip_played", {"entry_id": "le_1", "clip_source": "library"}),
        _event("clip_feedback_given", {"rating": "helpful", "clip_source": "library"}),
        _event("clip_reported", {"reason": "offensive", "clip_source": "library"}),
        _event("history_viewed", {"item_count": 3}),
        _event("history_replayed", {"entry_id": "le_1"}),
        _event("history_entry_removed", {"entry_id": "le_1"}),
    ]

    response = _ingest(gateway, events)

    assert response.status_code == 202, response.text
    assert response.json() == {"accepted": 6}


def test_an_event_outside_the_taxonomy_is_refused(gateway: httpx2.Client) -> None:
    # C-007 400: an unknown event name is refused before anything is stored.
    response = _ingest(gateway, [_event("clip_watched", {"entry_id": "le_1"})])

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "unknown_event"


def test_a_property_carrying_the_selected_word_is_refused(gateway: httpx2.Client) -> None:
    # analytics.md: no personal data in properties — never the word or phrase. A
    # property outside the event's taxonomy keys is refused.
    response = _ingest(gateway, [_event("clip_played", {"entry_id": "le_1", "word": "zorble"})])

    assert response.status_code == 400, response.text


def test_a_withdrawn_consent_suppresses_a_later_reading_event(gateway: httpx2.Client) -> None:
    # analytics.md "Analytics Data Governance": reading-behaviour events are
    # suppressed without model-processing consent. A withdrawal earlier in the
    # batch stops the gated event after it, so only the withdrawal is accepted.
    events = [
        _event("consent_changed", {"consent": False}),
        _event("clip_played", {"entry_id": "le_1", "clip_source": "library"}),
    ]

    response = _ingest(gateway, events)

    assert response.status_code == 202, response.text
    assert response.json() == {"accepted": 1}

"""Integration and acceptance tests for the polish-and-account event intake.

Verifies C-007 (`POST /v1/events`) against the events this phase adds to the
taxonomy: the preference change (EVT-016), the allowance running out with the
Paywall it opens (EVT-017, EVT-018), and the store purchase path (EVT-019 to
EVT-021). Each is accepted with the taxonomy's key properties, and none of the
purchase events is gated behind model-processing consent (analytics.md
"Analytics Data Governance": lifecycle and purchase events are not).
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]


def _auth(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _event(name: str, properties: dict[str, Any] | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "eventId": f"evt-{uuid4().hex}",
        "name": name,
        "occurredAt": "2026-10-16T12:00:00Z",
        "anonymousId": "anon-test",
        "sessionId": "ses-test",
        "platform": "android",
        "appVersion": "1.0.0",
        "locale": "en",
        "properties": properties or {},
    }
    return body


def _ingest(
    gateway: httpx2.Client, events: list[dict[str, Any]], *, subject: str = "reader-1"
) -> httpx2.Response:
    return gateway.post("/v1/events", headers=_auth(subject), json={"events": events})


def test_the_preferences_and_purchase_events_are_accepted(gateway: httpx2.Client) -> None:
    # The phase's events, each with its taxonomy key properties, are accepted
    # through the shipped intake (C-007 202 `accepted`).
    events = [
        _event("preference_changed", {"setting": "sound", "value": "on"}),
        _event("allowance_exhausted", {"plan": "free"}),
        _event("paywall_viewed", {"plan": "free", "lookups_used": 20}),
        _event(
            "purchase_started",
            {"product_id": "com.scenova.pro.monthly", "product_kind": "subscription"},
        ),
        _event(
            "purchase_completed",
            {"product_id": "com.scenova.pro.monthly", "product_kind": "subscription"},
        ),
        _event(
            "purchase_failed",
            {"product_id": "com.scenova.pro.monthly", "reason": "payment_declined"},
        ),
    ]

    response = _ingest(gateway, events)

    assert response.status_code == 202, response.text
    assert response.json() == {"accepted": 6}


def test_a_purchase_event_is_not_gated_behind_consent(gateway: httpx2.Client) -> None:
    # analytics.md "Analytics Data Governance": reading-behaviour events are
    # consent-gated; lifecycle and purchase events are not. A reader who has not
    # granted model-processing consent still tells the runbook their use of the
    # entitlement, or the purchase funnel the revenue reads would be blinded
    # exactly where consent least belongs to it.
    events = [
        _event(
            "purchase_started",
            {"product_id": "com.scenova.pro.monthly", "product_kind": "subscription"},
        ),
        _event("allowance_exhausted", {"plan": "free"}),
    ]

    response = _ingest(gateway, events, subject="no-consent-reader")

    assert response.status_code == 202, response.text
    assert response.json() == {"accepted": 2}


def test_a_preference_property_outside_the_taxonomy_is_refused(gateway: httpx2.Client) -> None:
    # C-007: a property outside the taxonomy's key set is refused, and personal
    # data never rides a property. The preference's value names the setting it
    # moved, never what the reader chose to read or who they are.
    response = _ingest(
        gateway,
        [_event("preference_changed", {"setting": "sound", "value": "on", "word": "pipewort"})],
    )

    assert response.status_code == 400, response.text
    assert set(response.json()) == {"code", "message"}

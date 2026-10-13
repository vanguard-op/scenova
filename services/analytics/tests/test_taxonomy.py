"""Taxonomy tests (`analytics.md` "Event Taxonomy").

The table must stay complete and closed: every `EVT-###` resolves, every event's
properties are bounded by its key-property column, and the consent-gated set is
the three reading-behaviour events the governance section names.
"""

from __future__ import annotations

import pytest

from analytics.app.errors import UnknownEventError
from analytics.app.taxonomy import (
    DEFAULT_GATED_EVENTS,
    EVENT_IDS,
    KEY_PROPERTIES,
    READING_BEHAVIOUR_EVENTS,
    EventName,
    allowed_properties,
    resolve_name,
    unknown_properties,
)


def test_every_event_has_an_id_and_key_properties() -> None:
    assert len(EventName) == 21
    for name in EventName:
        assert name in EVENT_IDS, name
        assert EVENT_IDS[name].startswith("EVT-")
        assert name in KEY_PROPERTIES, name


def test_ids_are_unique_and_sequential() -> None:
    ids = sorted(EVENT_IDS.values())
    assert ids[0] == "EVT-001"
    assert ids[-1] == "EVT-021"
    assert len(set(ids)) == 21


def test_resolve_name_accepts_the_wire_name() -> None:
    assert resolve_name("lookup_started") is EventName.LOOKUP_STARTED


def test_resolve_name_accepts_the_evt_anchor() -> None:
    assert resolve_name("EVT-005") is EventName.LOOKUP_STARTED


def test_resolve_name_rejects_an_unknown_name() -> None:
    with pytest.raises(UnknownEventError):
        resolve_name("heartbeat")


def test_key_properties_match_the_taxonomy() -> None:
    assert allowed_properties(EventName.LOOKUP_STARTED) == frozenset({"kind", "source"})
    assert allowed_properties(EventName.GENERATION_COMPLETED) == frozenset(
        {"model_version", "duration_ms", "cost_units", "resolution"}
    )
    assert allowed_properties(EventName.HISTORY_VIEWED) == frozenset({"item_count"})


def test_unknown_properties_reports_off_taxonomy_keys() -> None:
    assert unknown_properties(EventName.LOOKUP_SERVED, ["entry_id"]) == set()
    assert unknown_properties(EventName.LOOKUP_SERVED, ["entry_id", "email"]) == {"email"}


def test_consent_gated_set_is_the_reading_behaviour_events() -> None:
    assert DEFAULT_GATED_EVENTS == READING_BEHAVIOUR_EVENTS
    assert (
        frozenset({EventName.LOOKUP_STARTED, EventName.CLIP_PLAYED, EventName.HISTORY_VIEWED})
        == READING_BEHAVIOUR_EVENTS
    )

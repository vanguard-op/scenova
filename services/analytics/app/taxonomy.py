"""The product event taxonomy (`analytics.md` "Event Taxonomy").

This table is the intake's single source of truth. Every accepted event is one
of the `EVT-###` names, and each event's properties are that event's key
properties and nothing else — so a client cannot drift into free-form
properties, which is where personal data would leak in.

Version semantics, not names: when an event's meaning shifts, a property is
added or a new event introduced; an existing name is never redefined.
"""

from __future__ import annotations

from collections.abc import Iterable
from enum import StrEnum

from .errors import UnknownEventError


class EventName(StrEnum):
    """The wire name of each event in the taxonomy."""

    APP_OPENED = "app_opened"
    ONBOARDING_COMPLETED = "onboarding_completed"
    ACTION_ENABLED = "action_enabled"
    CONSENT_CHANGED = "consent_changed"
    LOOKUP_STARTED = "lookup_started"
    LOOKUP_SERVED = "lookup_served"
    GENERATION_STARTED = "generation_started"
    GENERATION_COMPLETED = "generation_completed"
    GENERATION_FAILED = "generation_failed"
    CLIP_PLAYED = "clip_played"
    CLIP_FEEDBACK_GIVEN = "clip_feedback_given"
    CLIP_REPORTED = "clip_reported"
    HISTORY_VIEWED = "history_viewed"
    HISTORY_REPLAYED = "history_replayed"
    HISTORY_ENTRY_REMOVED = "history_entry_removed"
    PREFERENCE_CHANGED = "preference_changed"
    ALLOWANCE_EXHAUSTED = "allowance_exhausted"
    PAYWALL_VIEWED = "paywall_viewed"
    PURCHASE_STARTED = "purchase_started"
    PURCHASE_COMPLETED = "purchase_completed"
    PURCHASE_FAILED = "purchase_failed"


# The stable `EVT-###` anchor for each name, as listed in the taxonomy.
EVENT_IDS: dict[EventName, str] = {
    EventName.APP_OPENED: "EVT-001",
    EventName.ONBOARDING_COMPLETED: "EVT-002",
    EventName.ACTION_ENABLED: "EVT-003",
    EventName.CONSENT_CHANGED: "EVT-004",
    EventName.LOOKUP_STARTED: "EVT-005",
    EventName.LOOKUP_SERVED: "EVT-006",
    EventName.GENERATION_STARTED: "EVT-007",
    EventName.GENERATION_COMPLETED: "EVT-008",
    EventName.GENERATION_FAILED: "EVT-009",
    EventName.CLIP_PLAYED: "EVT-010",
    EventName.CLIP_FEEDBACK_GIVEN: "EVT-011",
    EventName.CLIP_REPORTED: "EVT-012",
    EventName.HISTORY_VIEWED: "EVT-013",
    EventName.HISTORY_REPLAYED: "EVT-014",
    EventName.HISTORY_ENTRY_REMOVED: "EVT-015",
    EventName.PREFERENCE_CHANGED: "EVT-016",
    EventName.ALLOWANCE_EXHAUSTED: "EVT-017",
    EventName.PAYWALL_VIEWED: "EVT-018",
    EventName.PURCHASE_STARTED: "EVT-019",
    EventName.PURCHASE_COMPLETED: "EVT-020",
    EventName.PURCHASE_FAILED: "EVT-021",
}

# The taxonomy's "Key properties" column, per event. A property outside this set
# is refused: the taxonomy says "Do not track what can be derived" and "no
# personal data in properties".
KEY_PROPERTIES: dict[EventName, frozenset[str]] = {
    EventName.APP_OPENED: frozenset({"source"}),
    EventName.ONBOARDING_COMPLETED: frozenset({"action_enabled", "consent"}),
    EventName.ACTION_ENABLED: frozenset({"platform"}),
    EventName.CONSENT_CHANGED: frozenset({"consent"}),
    EventName.LOOKUP_STARTED: frozenset({"kind", "source"}),
    EventName.LOOKUP_SERVED: frozenset({"entry_id"}),
    EventName.GENERATION_STARTED: frozenset({"kind", "model_version"}),
    EventName.GENERATION_COMPLETED: frozenset(
        {"model_version", "duration_ms", "cost_units", "resolution"}
    ),
    EventName.GENERATION_FAILED: frozenset({"reason", "model_version"}),
    EventName.CLIP_PLAYED: frozenset({"entry_id", "clip_source"}),
    EventName.CLIP_FEEDBACK_GIVEN: frozenset({"rating", "clip_source"}),
    EventName.CLIP_REPORTED: frozenset({"reason", "clip_source"}),
    EventName.HISTORY_VIEWED: frozenset({"item_count"}),
    EventName.HISTORY_REPLAYED: frozenset({"entry_id"}),
    EventName.HISTORY_ENTRY_REMOVED: frozenset({"entry_id"}),
    EventName.PREFERENCE_CHANGED: frozenset({"setting", "value"}),
    EventName.ALLOWANCE_EXHAUSTED: frozenset({"plan"}),
    EventName.PAYWALL_VIEWED: frozenset({"plan", "lookups_used"}),
    EventName.PURCHASE_STARTED: frozenset({"product_id", "product_kind"}),
    EventName.PURCHASE_COMPLETED: frozenset({"product_id", "product_kind"}),
    EventName.PURCHASE_FAILED: frozenset({"product_id", "reason"}),
}

# The reading-behaviour events "Analytics Data Governance" consent-gates:
# "events that describe the reader's reading behaviour ... are suppressed until
# consent for model processing is granted; lifecycle and purchase events are
# not." This is the default for `ANALYTICS_CONSENT_GATED_EVENTS`.
READING_BEHAVIOUR_EVENTS: frozenset[EventName] = frozenset(
    {EventName.LOOKUP_STARTED, EventName.CLIP_PLAYED, EventName.HISTORY_VIEWED}
)
DEFAULT_GATED_EVENTS: frozenset[EventName] = READING_BEHAVIOUR_EVENTS

# The events that carry the reader's model-processing consent as a property, so
# the intake can notice a withdrawal.
CONSENT_EVENTS: frozenset[EventName] = frozenset(
    {EventName.ONBOARDING_COMPLETED, EventName.CONSENT_CHANGED}
)
CONSENT_PROPERTY = "consent"

_IDS_TO_NAMES: dict[str, EventName] = {evt_id: name for name, evt_id in EVENT_IDS.items()}


def resolve_name(raw: str) -> EventName:
    """Resolve a wire name (or its `EVT-###` anchor) to the taxonomy entry.

    The contract names the field "an EVT-### name"; the client sends the wire
    name, so both are accepted and normalised to the wire name.
    """

    try:
        return EventName(raw)
    except ValueError:
        pass
    resolved = _IDS_TO_NAMES.get(raw)
    if resolved is None:
        raise UnknownEventError(f"'{raw}' is not a known event name.")
    return resolved


def allowed_properties(name: EventName) -> frozenset[str]:
    """The only property keys an event of this name may carry."""

    return KEY_PROPERTIES[name]


def unknown_properties(name: EventName, keys: Iterable[str]) -> set[str]:
    """The property keys an event of this name may not carry."""

    allowed = KEY_PROPERTIES[name]
    return {key for key in keys if key not in allowed}

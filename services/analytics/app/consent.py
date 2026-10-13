"""Model-processing consent, as the intake can see it.

The account is the source of truth for consent (`schema.md` "Account"), and the
contract assigns the suppression of reading-behaviour events to the client
(C-007: "Events that describe reading behaviour are suppressed by the client
until model-processing consent is granted"). The intake therefore lets an
unknown subject through — it cannot know better — but it records the consent
carried on `consent_changed` and `onboarding_completed`, so a withdrawal it has
seen stops any later gated event. That is defence in depth, not the primary
gate.
"""

from __future__ import annotations

from enum import StrEnum


class ConsentState(StrEnum):
    """The reader's recorded model-processing consent."""

    GRANTED = "granted"
    WITHDRAWN = "withdrawn"


class ConsentRegistry:
    """Remembers consent per pseudonymous subject from consent-carrying events."""

    def __init__(self) -> None:
        self._states: dict[str, ConsentState] = {}

    def record(self, user_id: str, consent: bool) -> None:
        self._states[user_id] = ConsentState.GRANTED if consent else ConsentState.WITHDRAWN

    def is_withdrawn(self, user_id: str) -> bool:
        """Whether the subject has explicitly withdrawn consent."""

        return self._states.get(user_id) is ConsentState.WITHDRAWN

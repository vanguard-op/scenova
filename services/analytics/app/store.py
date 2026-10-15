"""The event store and its governance operations (`analytics.md` "Analytics Data
Governance").

Events are keyed by `event_id`, so a batch the client retried after a lost
response is stored once: the taxonomy calls the id "a unique id for this
occurrence", and the client queues and re-sends offline batches. The store also
carries the two data-lifecycle operations — retention and deletion
propagation — so the intake can satisfy them without a public query surface.
Raw reads stay behind the reporting layer's role check ("Analytics Data
Governance": access is for the product and finance roles); the intake exposes
none.

The in-memory store is the foundations-phase implementation; a Cloud SQL (or
BigQuery) store replaces it behind the same port.
"""

from __future__ import annotations

import asyncio
import calendar
from collections.abc import Mapping
from dataclasses import dataclass, replace
from datetime import datetime
from typing import Protocol

from .models import PropertyValue
from .taxonomy import EventName

# The pseudonymous identity an anonymized event is left under. It is a sentinel
# no token subject can hold, so the event can never be re-linked to a reader.
ANONYMIZED_USER_ID = "deleted"


@dataclass(frozen=True)
class StoredEvent:
    """One stored event, with the pseudonymous identity the intake resolved."""

    event_id: str
    name: EventName
    occurred_at: datetime
    user_id: str
    anonymous_id: str
    session_id: str
    platform: str
    app_version: str
    locale: str
    properties: Mapping[str, PropertyValue]
    received_at: datetime
    consent_gated: bool


class EventStore(Protocol):
    """Port for event persistence and its governance operations."""

    async def append(self, event: StoredEvent) -> bool:
        """Store an event; return False when its `event_id` is already stored."""
        ...

    async def get(self, event_id: str) -> StoredEvent | None: ...

    async def all(self) -> list[StoredEvent]: ...

    async def count(self) -> int: ...

    async def anonymize_subject(self, user_id: str) -> int:
        """Anonymize a subject's events for a data-subject request; return the count.

        The event is kept so the product's counts survive, but its pseudonymous
        identity — the `user_id` the account was resolved to, and the device and
        session identifiers — is severed, so the event can no longer be tied to
        the reader who made it (analytics.md "Analytics Data Governance").
        """
        ...

    async def purge_before(self, cutoff: datetime) -> dict[str, int]:
        """Aggregate and drop events received before the cutoff, by event name."""
        ...


class InMemoryEventStore:
    """An in-memory store keyed by `event_id`, insertion-ordered."""

    def __init__(self) -> None:
        self._events: dict[str, StoredEvent] = {}
        # Serialises append and the governance passes, so a delete or purge
        # cannot interleave with an append.
        self._lock = asyncio.Lock()

    async def append(self, event: StoredEvent) -> bool:
        async with self._lock:
            if event.event_id in self._events:
                return False
            self._events[event.event_id] = event
            return True

    async def get(self, event_id: str) -> StoredEvent | None:
        return self._events.get(event_id)

    async def all(self) -> list[StoredEvent]:
        return list(self._events.values())

    async def count(self) -> int:
        return len(self._events)

    async def anonymize_subject(self, user_id: str) -> int:
        async with self._lock:
            affected = [
                event_id for event_id, event in self._events.items() if event.user_id == user_id
            ]
            for event_id in affected:
                event = self._events[event_id]
                self._events[event_id] = replace(
                    event,
                    user_id=ANONYMIZED_USER_ID,
                    anonymous_id="",
                    session_id="",
                )
            return len(affected)

    async def purge_before(self, cutoff: datetime) -> dict[str, int]:
        async with self._lock:
            aggregated: dict[str, int] = {}
            expired = [
                event_id for event_id, event in self._events.items() if event.received_at < cutoff
            ]
            for event_id in expired:
                name = self._events[event_id].name
                aggregated[name.value] = aggregated.get(name.value, 0) + 1
                del self._events[event_id]
            return aggregated


def months_ago(moment: datetime, months: int) -> datetime:
    """The instant `months` calendar months before `moment`.

    Calendar months, not a day count, so the retention window matches the
    fourteen months the data lifecycle states.
    """

    month_index = moment.month - 1 - months
    year = moment.year + month_index // 12
    month = month_index % 12 + 1
    day = min(moment.day, calendar.monthrange(year, month)[1])
    return moment.replace(year=year, month=month, day=day)


def retention_cutoff(now: datetime, months: int) -> datetime:
    """Events received before this instant are due for aggregation or deletion."""

    return months_ago(now, months)

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

Two implementations sit behind one port: the in-memory store the unit tests and
a bare local run use, and the relational store that is the primary database
(architecture.md "Analytics / Event Tracking": the event store is the primary
database, not a second engine), so an accepted event is kept durably and
survives a restart of the intake. A caller cannot tell them apart.
"""

from __future__ import annotations

import asyncio
import calendar
import json
from collections.abc import Mapping
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Protocol

from sqlalchemy import delete, func, select, update
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .db import EventRow
from .db import create_engine as create_relational_engine
from .errors import EventStoreUnavailableError
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


class PostgresEventStore:
    """The event store in the primary relational database — one `events` row per
    stored event, keyed by `event_id` (`analytics.md` "Event Taxonomy").

    Every accepted event is written to the primary database before the intake
    acknowledges it, so an event survives a restart of the intake
    (architecture.md "Analytics / Event Tracking"). Each call runs its query on
    a worker thread, so a slow database never blocks the event loop the batch
    intake runs on (NFR-006); every failure to reach the database is reported as
    the store being unavailable, so the intake answers 503 and the client
    retries its batch — the `event_id` key keeps that retry idempotent.

    The retention pass aggregates and drops the events received before the
    cutoff, keyed by event name, and a data-subject deletion severs the
    reader's identity across the store while the event itself stays, so counts
    are unaffected (`analytics.md` "Analytics Data Governance").
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def append(self, event: StoredEvent) -> bool:
        return await asyncio.to_thread(self._append, event)

    async def get(self, event_id: str) -> StoredEvent | None:
        return await asyncio.to_thread(self._get, event_id)

    async def all(self) -> list[StoredEvent]:
        return await asyncio.to_thread(self._all)

    async def count(self) -> int:
        return await asyncio.to_thread(self._count)

    async def anonymize_subject(self, user_id: str) -> int:
        return await asyncio.to_thread(self._anonymize_subject, user_id)

    async def purge_before(self, cutoff: datetime) -> dict[str, int]:
        return await asyncio.to_thread(self._purge_before, cutoff)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    # --- synchronous bodies, each run on a worker thread ----------------------

    def _append(self, event: StoredEvent) -> bool:
        try:
            with self._sessions() as session, session.begin():
                existing = session.scalar(
                    select(EventRow.event_id).where(EventRow.event_id == event.event_id)
                )
                if existing is not None:
                    return False
                session.add(
                    EventRow(
                        event_id=event.event_id,
                        name=event.name.value,
                        occurred_at=_iso(event.occurred_at),
                        user_id=event.user_id,
                        anonymous_id=event.anonymous_id,
                        session_id=event.session_id,
                        platform=event.platform,
                        app_version=event.app_version,
                        locale=event.locale,
                        properties=json.loads(json.dumps(dict(event.properties))),
                        received_at=_iso(event.received_at),
                        consent_gated=event.consent_gated,
                    )
                )
                return True
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _get(self, event_id: str) -> StoredEvent | None:
        try:
            with self._sessions() as session:
                row = session.scalar(select(EventRow).where(EventRow.event_id == event_id))
                return None if row is None else _event(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _all(self) -> list[StoredEvent]:
        try:
            with self._sessions() as session:
                rows = session.scalars(select(EventRow).order_by(EventRow.received_at)).all()
                return [_event(row) for row in rows]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _count(self) -> int:
        try:
            with self._sessions() as session:
                return session.scalar(select(func.count()).select_from(EventRow)) or 0
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _anonymize_subject(self, user_id: str) -> int:
        try:
            with self._sessions() as session, session.begin():
                result = session.execute(
                    update(EventRow)
                    .where(EventRow.user_id == user_id)
                    .values(
                        user_id=ANONYMIZED_USER_ID,
                        anonymous_id="",
                        session_id="",
                    )
                )
                # The consent state the intake holds for the subject is the
                # service's, so only the store's share of the severing is here.
                return int(result.rowcount or 0)  # type: ignore[attr-defined]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _purge_before(self, cutoff: datetime) -> dict[str, int]:
        try:
            with self._sessions() as session, session.begin():
                counts = session.execute(
                    select(EventRow.name, func.count())
                    .where(EventRow.received_at < _iso(cutoff))
                    .group_by(EventRow.name)
                ).all()
                if not counts:
                    return {}
                session.execute(delete(EventRow).where(EventRow.received_at < _iso(cutoff)))
                return {name: int(count) for name, count in counts}
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def _event(row: EventRow) -> StoredEvent:
    return StoredEvent(
        event_id=row.event_id,
        name=EventName(row.name),
        occurred_at=_utc(row.occurred_at),
        user_id=row.user_id,
        anonymous_id=row.anonymous_id,
        session_id=row.session_id,
        platform=row.platform,
        app_version=row.app_version,
        locale=row.locale,
        properties=dict(row.properties or {}),
        received_at=_utc(row.received_at),
        consent_gated=row.consent_gated,
    )


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat()


def _utc(raw: str) -> datetime:
    return datetime.fromisoformat(raw).astimezone(UTC)


def _unavailable() -> EventStoreUnavailableError:
    return EventStoreUnavailableError("The event store is unavailable.")


def build_default_store(database_url: str | None) -> EventStore:
    """The store a running intake uses.

    An empty `DATABASE_URL` resolves to the in-memory store, which the unit
    tests and a bare local run use; a configured database resolves to the
    primary relational store (architecture.md "Analytics / Event Tracking": the
    event store is the primary database, not a second engine).
    """

    if database_url is None:
        return InMemoryEventStore()
    return PostgresEventStore(create_relational_engine(database_url))


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

"""Push-registration and pending-notice persistence (C-008, FEAT-008; schema.md
"PushRegistration", "PendingNotice").

A registration binds a push token to the lookup the reader is waiting on, so a
finished generation reaches exactly the devices that asked for it. The store is
keyed by lookup and deduplicates a repeated device, since a reader may register
the same device more than once.

Each clip-ready ingest consumes a lookup's registrations exactly once: the
consumption and the dedupe are the same rows, so a retried ingest never finds a
registration to notify again, and nothing is held for a lookup whose devices
were already addressed.

A notice the provider cannot take is held as a pending notice and drains oldest
first once the provider is back; a delivered notice is removed, so the queue
never grows beyond what is undelivered. Two implementations sit behind one port:
the in-memory pair the unit tests and a bare local run use, and the relational
store that is the primary database (architecture.md "Notification Service"),
where a provider outage or a restart delays the notice rather than losing it. A
caller cannot tell them apart.
"""

from __future__ import annotations

import asyncio
import logging
from collections import deque
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol
from uuid import uuid4

from sqlalchemy import delete, func, select
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .db import PendingNoticeRow, PushRegistrationRow
from .db import create_engine as create_relational_engine
from .errors import PushStoreUnavailableError
from .models import Platform

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class PushRegistration:
    """One device registered for a lookup's clip-ready notice."""

    token: str
    platform: Platform
    subject: str
    lookup_id: str


@dataclass(frozen=True)
class QueuedNotice:
    """A clip-ready notice held for delivery (schema "PendingNotice").

    The finished job the ingest named is deliberately not a field: the queued
    payload is the C-008 notice's data payload — the lookup and the clip — and
    that payload is all a restarted service resumes with.
    """

    id: str
    lookup_id: str
    token: str
    platform: Platform
    clip_url: str
    duration_seconds: float
    resolution: str
    has_audio: bool


class RegistrationStore(Protocol):
    """Port for push-registration persistence."""

    async def add(self, registration: PushRegistration) -> None:
        """Record a device for a lookup, replacing the same device if repeated."""
        ...

    async def consume(self, lookup_id: str) -> list[PushRegistration]:
        """Return and clear the devices registered for a lookup, once."""
        ...

    async def aclose(self) -> None: ...


class NoticeQueue(Protocol):
    """Port for the pending-notice queue."""

    async def enqueue(self, notices: Iterable[QueuedNotice]) -> list[QueuedNotice]:
        """Hold notices for delivery, dropping the oldest past the queue's
        bound; return the notices the queue actually holds."""
        ...

    async def outstanding(self) -> list[QueuedNotice]:
        """The notices the provider has not accepted yet, oldest first."""
        ...

    async def mark_delivered(self, notice_ids: Sequence[str]) -> None:
        """Remove the notices the provider accepted, so delivery is not repeated."""
        ...

    async def aclose(self) -> None: ...


class InMemoryRegistrationStore:
    """An in-memory registration store, keyed by lookup."""

    def __init__(self) -> None:
        self._by_lookup: dict[str, dict[tuple[str, str], PushRegistration]] = {}

    async def add(self, registration: PushRegistration) -> None:
        devices = self._by_lookup.setdefault(registration.lookup_id, {})
        devices[(registration.token, registration.platform.value)] = registration

    async def consume(self, lookup_id: str) -> list[PushRegistration]:
        return list(self._by_lookup.pop(lookup_id, {}).values())

    async def aclose(self) -> None:
        return None


class InMemoryNoticeQueue:
    """An in-memory pending-notice queue, oldest first.

    The bound keeps a long outage from growing the queue without limit; the
    oldest notice goes first, matching a queue that drains in order.
    """

    def __init__(self, *, limit: int = 1000) -> None:
        self._pending: deque[QueuedNotice] = deque()
        self._limit = max(1, limit)

    async def enqueue(self, notices: Iterable[QueuedNotice]) -> list[QueuedNotice]:
        held = list(notices)
        self._pending.extend(held)
        while len(self._pending) > self._limit:
            dropped = self._pending.popleft()
            if dropped in held:
                held.remove(dropped)
            logger.warning("the queued-notice limit was reached; the oldest notice was dropped")
        return held

    async def outstanding(self) -> list[QueuedNotice]:
        return list(self._pending)

    async def mark_delivered(self, notice_ids: Sequence[str]) -> None:
        delivered = set(notice_ids)
        self._pending = deque(n for n in self._pending if n.id not in delivered)

    async def aclose(self) -> None:
        return None


class PostgresPushStore:
    """Push registrations and pending notices in the primary relational database
    (`infra/db/migrations`: `push_registrations`, `pending_notices`).

    Each call runs its query on a worker thread, so a slow database never blocks
    the event loop a registration or a drain runs on (NFR-006). Every failure to
    reach the database is reported as the store being unavailable, so the
    registration answers 503 and the client retries, and the pipeline retries
    the clip-ready ingest whose registrations were not consumed.

    The queue's bound is carried here too: a long outage cannot grow
    `pending_notices` without limit, and the oldest notice goes first.
    """

    def __init__(self, engine: Engine, *, pending_limit: int = 1000) -> None:
        self._engine = engine
        self._pending_limit = max(1, pending_limit)
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    # --- registration store ---------------------------------------------------

    async def add(self, registration: PushRegistration) -> None:
        await asyncio.to_thread(self._add, registration)

    async def consume(self, lookup_id: str) -> list[PushRegistration]:
        return await asyncio.to_thread(self._consume, lookup_id)

    # --- pending-notice queue -------------------------------------------------

    async def enqueue(self, notices: Iterable[QueuedNotice]) -> list[QueuedNotice]:
        return await asyncio.to_thread(self._enqueue, list(notices))

    async def outstanding(self) -> list[QueuedNotice]:
        return await asyncio.to_thread(self._outstanding)

    async def mark_delivered(self, notice_ids: Sequence[str]) -> None:
        await asyncio.to_thread(self._mark_delivered, list(notice_ids))

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    # --- synchronous bodies, each run on a worker thread ----------------------

    def _add(self, registration: PushRegistration) -> None:
        try:
            with self._sessions() as session, session.begin():
                # A reader may register the same device twice; the row that is
                # already there wins, so the association stays one per device.
                existing = session.scalar(
                    select(PushRegistrationRow).where(
                        PushRegistrationRow.lookup_id == registration.lookup_id,
                        PushRegistrationRow.device_token == registration.token,
                        PushRegistrationRow.platform == registration.platform.value,
                    )
                )
                if existing is not None:
                    return
                session.add(
                    PushRegistrationRow(
                        id=f"pr_{uuid4().hex}",
                        lookup_id=registration.lookup_id,
                        subject=registration.subject,
                        device_token=registration.token,
                        platform=registration.platform.value,
                        created_at=_now(),
                    )
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _consume(self, lookup_id: str) -> list[PushRegistration]:
        try:
            with self._sessions() as session, session.begin():
                rows = session.scalars(
                    select(PushRegistrationRow).where(PushRegistrationRow.lookup_id == lookup_id)
                ).all()
                consumed = [
                    PushRegistration(
                        token=row.device_token,
                        platform=Platform(row.platform),
                        subject=row.subject,
                        lookup_id=row.lookup_id,
                    )
                    for row in rows
                ]
                if rows:
                    session.execute(
                        delete(PushRegistrationRow).where(
                            PushRegistrationRow.lookup_id == lookup_id
                        )
                    )
                return consumed
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _enqueue(self, notices: list[QueuedNotice]) -> list[QueuedNotice]:
        try:
            with self._sessions() as session, session.begin():
                held = list(notices)
                stored = session.scalar(select(func.count()).select_from(PendingNoticeRow)) or 0
                excess = stored + len(held) - self._pending_limit
                if excess > 0:
                    oldest = session.scalars(
                        select(PendingNoticeRow.id)
                        .order_by(PendingNoticeRow.created_at, PendingNoticeRow.id)
                        .limit(excess)
                    ).all()
                    if oldest:
                        session.execute(
                            delete(PendingNoticeRow).where(PendingNoticeRow.id.in_(oldest))
                        )
                        logger.warning(
                            "the queued-notice limit was reached; the oldest notice was dropped"
                        )
                for notice in held:
                    session.add(
                        PendingNoticeRow(
                            id=notice.id,
                            lookup_id=notice.lookup_id,
                            device_token=notice.token,
                            platform=notice.platform.value,
                            clip_url=notice.clip_url,
                            duration_seconds=notice.duration_seconds,
                            resolution=notice.resolution,
                            has_audio=notice.has_audio,
                            created_at=_now(),
                        )
                    )
                return held
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _outstanding(self) -> list[QueuedNotice]:
        try:
            with self._sessions() as session:
                rows = session.scalars(
                    select(PendingNoticeRow).order_by(
                        PendingNoticeRow.created_at, PendingNoticeRow.id
                    )
                ).all()
                return [
                    QueuedNotice(
                        id=row.id,
                        lookup_id=row.lookup_id,
                        token=row.device_token,
                        platform=Platform(row.platform),
                        clip_url=row.clip_url,
                        duration_seconds=row.duration_seconds,
                        resolution=row.resolution,
                        has_audio=row.has_audio,
                    )
                    for row in rows
                ]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _mark_delivered(self, notice_ids: list[str]) -> None:
        if not notice_ids:
            return
        try:
            with self._sessions() as session, session.begin():
                session.execute(delete(PendingNoticeRow).where(PendingNoticeRow.id.in_(notice_ids)))
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def build_default_store(
    database_url: str | None, *, pending_limit: int = 1000
) -> tuple[RegistrationStore, NoticeQueue]:
    """The store pair a running service uses.

    An empty `DATABASE_URL` resolves to the in-memory pair, which the unit tests
    and a bare local run use; a configured database resolves to the primary
    relational store (architecture.md "Data Stores": the primary database holds
    the push registrations and the pending clip-ready notices).
    """

    if database_url is None:
        return InMemoryRegistrationStore(), InMemoryNoticeQueue(limit=pending_limit)
    relational = PostgresPushStore(
        create_relational_engine(database_url), pending_limit=pending_limit
    )
    return relational, relational


def _unavailable() -> PushStoreUnavailableError:
    return PushStoreUnavailableError("The push store is unavailable.")


def _now() -> str:
    return datetime.now(UTC).isoformat()

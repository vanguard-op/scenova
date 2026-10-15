"""Relational persistence for the product events (C-007; `analytics.md`
"Analytics Data Governance").

The event store is the primary database, not a second engine (architecture.md
"Analytics / Event Tracking"): the intake writes each accepted event there
before the event is treated as accepted, so an event is kept durably and
survives a restart of the intake, and the retention and deletion rules the docs
already apply to the primary store hold for events (`nfr.md` "Data lifecycle";
`analytics.md` "Analytics Data Governance"). One `events` row per stored event,
keyed by `event_id`, so a batch the client retried after a lost response is
stored once.

The properties an event carries are taxonomy-bounded and scanned for personal
data before they are stored, so the JSON column can hold nothing that names the
reader: events carry the pseudonymous `user_id`, never an email, a name, the
selected word, or free text (`analytics.md` "Event Taxonomy").
"""

from __future__ import annotations

from sqlalchemy import JSON, Boolean, String, Text
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from .models import PropertyValue


class Base(DeclarativeBase):
    """Base for the analytics service's relational tables."""


class EventRow(Base):
    """One stored product event (`analytics.md` "Event Taxonomy")."""

    __tablename__ = "events"

    # "a unique id for this occurrence": the key a retried batch deduplicates on.
    event_id: Mapped[str] = mapped_column(Text, primary_key=True)
    name: Mapped[str] = mapped_column(Text)
    occurred_at: Mapped[str] = mapped_column(String(64))
    # The pseudonymous identity the intake resolved the authenticated subject to
    # ("user_id (pseudonymous)"). Anonymization replaces it with a sentinel and
    # empties the device and session identifiers beside it.
    user_id: Mapped[str] = mapped_column(Text)
    anonymous_id: Mapped[str] = mapped_column(Text)
    session_id: Mapped[str] = mapped_column(Text)
    platform: Mapped[str] = mapped_column(String(16))
    app_version: Mapped[str] = mapped_column(String(64))
    locale: Mapped[str] = mapped_column(String(64))
    properties: Mapped[dict[str, PropertyValue]] = mapped_column(JSON, nullable=False)
    received_at: Mapped[str] = mapped_column(String(64))
    # Whether the event describes reading behaviour that consent gates.
    consent_gated: Mapped[bool] = mapped_column(Boolean)


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a store call that cannot reach it raises
    the event store's unavailable error, so the intake answers 503 and the
    client retries its batch (C-007; NFR-024's pattern). The store offloads each
    call to a worker thread, so a slow query never blocks the event loop the
    batch intake runs on (NFR-006). `pool_pre_ping` discards a connection the
    database has dropped, so a failover is transparent to the next call.
    """

    return _create_engine(database_url, pool_pre_ping=True)

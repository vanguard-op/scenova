"""Relational persistence for push registrations and pending notices (C-008,
FEAT-008).

The push store is the primary database's durable half for the notification
service (architecture.md "Notification Service": a device that takes the notify
offer is registered in the primary database, and a notice that cannot be
delivered is held there as a pending notice, so a provider outage or a restart
delays the notice rather than losing it): one `push_registrations` row per
device registered for a lookup's clip-ready notice, and one `pending_notices`
row for each notice a send has not yet reached (schema.md "PushRegistration",
"PendingNotice").

The tables are the platform's migration history (`infra/db/migrations`); the
classes here map that schema for reads and writes and never create it — a table
that is missing or unreachable surfaces as the push store being unavailable,
not as a schema the service invents.
"""

from __future__ import annotations

from sqlalchemy import Boolean, Float, String, Text, UniqueConstraint
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base for the notification service's relational tables."""


class PushRegistrationRow(Base):
    """One device registered for a lookup's clip-ready notice (schema
    "PushRegistration")."""

    __tablename__ = "push_registrations"
    __table_args__ = (
        # The store is keyed by lookup and deduplicates a repeated device: a
        # reader may register the same token twice, and one row wins (C-008).
        UniqueConstraint(
            "lookup_id", "device_token", "platform", name="uq_push_registrations_device"
        ),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    # The lookup the device asked to be notified about; the migration holds the
    # foreign key to `lookups` (schema "PushRegistration": `lookupId`).
    lookup_id: Mapped[str] = mapped_column(String(64))
    subject: Mapped[str] = mapped_column(Text)
    device_token: Mapped[str] = mapped_column(Text)
    platform: Mapped[str] = mapped_column(Text)
    created_at: Mapped[str] = mapped_column(String(64))


class PendingNoticeRow(Base):
    """A clip-ready notice the push provider has not yet accepted (schema
    "PendingNotice").

    The row carries the notice's data payload exactly as C-008's notice does:
    the finished clip's retrieval reference and its playing facts. The word and
    phrase are deliberately absent — the payload carries the lookup id, so
    nothing about the reader's selection reaches the push provider.
    """

    __tablename__ = "pending_notices"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    lookup_id: Mapped[str] = mapped_column(String(64))
    device_token: Mapped[str] = mapped_column(Text)
    platform: Mapped[str] = mapped_column(Text)
    clip_url: Mapped[str] = mapped_column(Text)
    duration_seconds: Mapped[float] = mapped_column(Float)
    resolution: Mapped[str] = mapped_column(String(16))
    has_audio: Mapped[bool] = mapped_column(Boolean)
    created_at: Mapped[str] = mapped_column(String(64))


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a store call that cannot reach it raises
    the push store's unavailable error, so the registration answers 503 and the
    pipeline retries the clip-ready ingest. The store offloads each call to a
    worker thread, so a slow query never blocks the event loop a registration
    or a drain runs on (NFR-006). `pool_pre_ping` discards a connection the
    database has dropped, so a failover is transparent to the next call rather
    than a spurious 503.
    """

    return _create_engine(database_url, pool_pre_ping=True)

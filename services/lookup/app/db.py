"""Relational persistence for lookup records (schema.md "Lookup").

A lookup is personal data: `subject` is the account (or anonymous identity) that
made it, `raw_selection` is the word or phrase as selected, and
`normalised_lemma` is the key it reduced to. The senses the lookup resolved to
are held in `lookup_senses`, and the generation jobs a poll is waiting on in
`lookup_generation_jobs`; both are child rows, so a reader's deletion removes
them with the lookup rather than leaving the selection restated beside it
(nfr.md "Privacy & Compliance"). The row itself survives anonymized, so usage
counts outlive the reader's identity.

The tables are the platform's migration history (`infra/db/migrations`, applied
by `make db-migrate` locally and by the migration job in the cloud); the classes
here map that schema for reads and writes and never create it. `account_id` and
`served_entry_id` reference tables another service owns (`accounts`,
`library_entries`); the migration declares those foreign keys, and this service
maps the columns without re-declaring the tables, so it never needs another
service's schema to be importable.
"""

from __future__ import annotations

from sqlalchemy import Boolean, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """Base for the lookup service's relational tables."""


class LookupRow(Base):
    """One lookup a reader made (schema "Lookup")."""

    __tablename__ = "lookups"
    __table_args__ = (
        # The idempotency key is unique per caller. An anonymized lookup's key is
        # dropped to NULL, and NULLs compare distinct, so any number of
        # anonymized rows can sit under the sentinel subject.
        UniqueConstraint("subject", "client_lookup_id", name="uq_lookup_client"),
    )

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    subject: Mapped[str] = mapped_column(Text)
    client_lookup_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The account that made the lookup, or NULL for a guest or a pre-account
    # lookup; the migration holds the foreign key to `accounts`.
    account_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    raw_selection: Mapped[str] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(String(16))
    normalised_lemma: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The library entry the lookup was served from, when it hit the library; the
    # migration holds the foreign key to `library_entries`.
    served_entry_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    status: Mapped[str] = mapped_column(String(16))
    notice: Mapped[str | None] = mapped_column(Text, nullable=True)
    allowance_used: Mapped[int | None] = mapped_column(Integer, nullable=True)
    allowance_limit: Mapped[int | None] = mapped_column(Integer, nullable=True)
    allowance_period_end: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(String(64))

    senses: Mapped[list[LookupSenseRow]] = relationship(
        back_populates="lookup",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="LookupSenseRow.position",
    )
    generation_jobs: Mapped[list[LookupJobRow]] = relationship(
        back_populates="lookup",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="LookupJobRow.position",
    )


class LookupSenseRow(Base):
    """One sense a lookup resolved to, as it was served to the reader."""

    __tablename__ = "lookup_senses"

    lookup_id: Mapped[str] = mapped_column(String(64), ForeignKey("lookups.id"), primary_key=True)
    position: Mapped[int] = mapped_column(Integer, primary_key=True)
    sense_label: Mapped[str] = mapped_column(Text)
    part_of_speech: Mapped[str] = mapped_column(String(16))
    gloss_phrase: Mapped[str] = mapped_column(Text)
    entry_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    clip_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    clip_duration_seconds: Mapped[float | None] = mapped_column(Float, nullable=True)
    clip_resolution: Mapped[str | None] = mapped_column(String(16), nullable=True)
    clip_has_audio: Mapped[bool | None] = mapped_column(Boolean, nullable=True)

    lookup: Mapped[LookupRow] = relationship(back_populates="senses")


class LookupJobRow(Base):
    """One generation job a lookup is waiting on (C-006)."""

    __tablename__ = "lookup_generation_jobs"

    lookup_id: Mapped[str] = mapped_column(String(64), ForeignKey("lookups.id"), primary_key=True)
    position: Mapped[int] = mapped_column(Integer, primary_key=True)
    job_id: Mapped[str] = mapped_column(Text)

    lookup: Mapped[LookupRow] = relationship(back_populates="generation_jobs")


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a lookup that cannot be recorded raises
    the unavailable error and the API answers 503 rather than losing the record
    (C-001). The store offloads each call to a worker thread, so a slow query
    never blocks the event loop the reader's lookup runs on (NFR-002).
    `pool_pre_ping` discards a connection the database has dropped, so a failover
    is transparent to the next lookup.
    """

    return _create_engine(database_url, pool_pre_ping=True)

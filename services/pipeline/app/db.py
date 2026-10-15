"""Relational persistence for generation jobs (schema.md "GenerationJob").

One `generation_jobs` row per job the lookup service enqueues: the lookup it
belongs to, whether it is a word or a phrase job, the gloss phrase the clip is
generated from, the state it reached, how many attempts it took, the two pinned
models it is attributable to, and the generation cost it accrued (schema
"GenerationJob").

The pipeline needs four fields the entity does not carry, so the row holds them
too: the library key of the sense the job generates for (`sense_label`,
`part_of_speech`), the clip duration the job targets, and the correlation id the
enqueue arrived with, which ties a generation event back to the lookup that
started it. Without them a job read back by id could not generate, write the word
clip under its sense, or be traced to its lookup.

The table is the platform's migration history (`infra/db/migrations`, applied by
`make db-migrate` locally and by the migration job in the cloud); the class here
maps that schema for reads and writes and never creates it. A table that is
missing or unreachable surfaces as the queue being unavailable, so the enqueue
answers 503 and the caller resolves the reader to the fallback (C-003).
"""

from __future__ import annotations

from sqlalchemy import Float, Integer, String, Text
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base for the generation pipeline's relational tables."""


class GenerationJobRow(Base):
    """One asynchronous job that produces a clip for a lookup (schema "GenerationJob")."""

    __tablename__ = "generation_jobs"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    # The lookup the job belongs to; the migration holds the foreign key to
    # `lookups` (schema "GenerationJob": `lookupId`), and the lookup service owns
    # that table, so it is mapped here as a plain reference rather than declared.
    lookup_id: Mapped[str] = mapped_column(String(64))
    kind: Mapped[str] = mapped_column(String(16))
    lemma: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Null while a word job is queued: the pipeline generates the phrase via C-004
    # before the clip step.
    phrase: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(16))
    attempts: Mapped[int] = mapped_column(Integer)
    phrase_model: Mapped[str] = mapped_column(Text)
    clip_model: Mapped[str] = mapped_column(Text)
    cost_units: Mapped[float] = mapped_column(Float)
    created_at: Mapped[str] = mapped_column(String(64))
    completed_at: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # The library key the job generates for, the clip duration it targets, and
    # the correlation id its generation events carry.
    sense_label: Mapped[str] = mapped_column(Text)
    part_of_speech: Mapped[str] = mapped_column(String(16))
    target_duration_seconds: Mapped[float] = mapped_column(Float)
    correlation_id: Mapped[str] = mapped_column(String(64))


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a queue call that cannot reach it raises
    the queue's unavailable error, so the enqueue answers 503 and the lookup
    resolves the reader to the fallback (C-003). The queue offloads each call to
    a worker thread, so a slow query never blocks the event loop a job runs on
    (NFR-006). `pool_pre_ping` discards a connection the database has dropped, so
    a failover is transparent to the next call rather than a spurious 503.
    """

    return _create_engine(database_url, pool_pre_ping=True)

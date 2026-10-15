"""Relational persistence for the shared word-clip library (FEAT-006).

The library is the primary database's relational half (architecture.md "Data
Architecture"): one `library_entries` row per lemma and sense, each referencing
the `clip_assets` row that holds its word clip (schema.md "LibraryEntry" and
"ClipAsset"). A clip regenerated for a reporting reader is held as the entry's
`candidate_clip_asset_id`, beside the clip it already serves, until a curator
chooses which one serves (FEAT-011, FEAT-015). Word entries only: a phrase clip
never reaches these tables (FEAT-007).

The tables are the platform's migration history (`infra/db/migrations`, applied
by `make db-migrate` locally and by the migration job in the cloud); the classes
here map that schema for reads and writes and never create it. A table that is
missing or unreachable surfaces as the library being unavailable, not as a
schema the service invents.
"""

from __future__ import annotations

from sqlalchemy import Boolean, Float, ForeignKey, String, UniqueConstraint
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    """Base for the library's relational tables."""


class ClipAssetRow(Base):
    """A generated word clip stored centrally (schema "ClipAsset")."""

    __tablename__ = "clip_assets"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    duration_seconds: Mapped[float] = mapped_column(Float)
    resolution: Mapped[str] = mapped_column(String(16))
    storage_key: Mapped[str] = mapped_column(String(1024))
    url: Mapped[str] = mapped_column(String(2048))
    has_audio: Mapped[bool] = mapped_column(Boolean)
    synth_id_watermark: Mapped[bool] = mapped_column(Boolean)
    created_at: Mapped[str] = mapped_column(String(64))


class LibraryEntryRow(Base):
    """A shared library entry keyed by lemma and sense (schema "LibraryEntry").

    `lemma_key` is the case-folded lemma the key is matched on, so a lookup for
    "Come" and one for "come" reach the same entry. The `lemma` column keeps the
    form the entry was stored under, for display.
    """

    __tablename__ = "library_entries"
    __table_args__ = (
        UniqueConstraint(
            "lemma_key",
            "sense_label",
            "part_of_speech",
            name="uq_library_entry_key",
        ),
    )

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    lemma_key: Mapped[str] = mapped_column(String(128))
    lemma: Mapped[str] = mapped_column(String(128))
    part_of_speech: Mapped[str] = mapped_column(String(16))
    sense_label: Mapped[str] = mapped_column(String(128))
    gloss_phrase: Mapped[str] = mapped_column(String(60))
    clip_asset_id: Mapped[str] = mapped_column(String(64), ForeignKey("clip_assets.id"))
    candidate_clip_asset_id: Mapped[str | None] = mapped_column(
        String(64), ForeignKey("clip_assets.id"), nullable=True
    )
    status: Mapped[str] = mapped_column(String(16))
    source: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[str] = mapped_column(String(64))
    updated_at: Mapped[str] = mapped_column(String(64))

    # Both clips are loaded with the entry, so a read never falls back to a lazy
    # load the worker thread's session cannot serve.
    asset: Mapped[ClipAssetRow] = relationship(foreign_keys=[clip_asset_id], lazy="joined")
    candidate: Mapped[ClipAssetRow | None] = relationship(
        foreign_keys=[candidate_clip_asset_id], lazy="joined"
    )


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a store call that cannot reach it raises
    the library's unavailable error and the API answers 503 (C-009 to C-011,
    C-017). The store offloads each call to a worker thread, so a slow query
    never blocks the event loop the reader's lookup runs on (NFR-002).
    `pool_pre_ping` discards a connection the database has dropped, so a failover
    is transparent to the next read rather than a spurious 503.
    """

    return _create_engine(database_url, pool_pre_ping=True)

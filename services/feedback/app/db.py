"""Relational persistence for feedback, reports, and the review queue (FEAT-010,
FEAT-011, FEAT-015).

The feedback store is the primary database's relational half (architecture.md
"Data Architecture": review records and feedback): one `feedback` row per
reader's rating of a lookup, one `reports` row per reader's report, the
`review_items` row that holds an entry's place in the curator's queue, and the
`moderation_actions` row every curator action records (schema.md "Feedback",
"Report", "ReviewItem", "ModerationAction").

A rating and a report are personal data (schema "Feedback", "Report":
`accountId`), so `subject` is the reader who made them and the client idempotency
keys tie them to that reader. A data-subject deletion strips the identity and
drops the keys, leaving the rating, reason, and timestamps as usage evidence
(nfr.md "Privacy & Compliance"; analytics.md "Analytics Data Governance"); the
columns are nullable so that deletion can drop them.

The entry a rating or report is about is reached through the lookup that served
it: schema "Feedback" and "Report" carry `lookupId`, and schema "Lookup" carries
`servedEntryId`. The `lookups` and `library_entries` tables are owned by other
services, so they are mapped here as read-only references and never declared:
the migration history (`infra/db/migrations`) is the one schema, and this service
maps only the columns it reads.

The tables are the platform's migration history, applied by `make db-migrate`
locally and by the migration job in the cloud; the classes here map that schema
for reads and writes and never create it. A table that is missing or unreachable
surfaces as the feedback store being unavailable, not as a schema the service
invents.
"""

from __future__ import annotations

from sqlalchemy import Boolean, Column, MetaData, String, Table, Text, UniqueConstraint
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base for the feedback service's relational tables."""


class FeedbackRow(Base):
    """One reader's rating of one lookup (schema "Feedback")."""

    __tablename__ = "feedback"
    __table_args__ = (
        UniqueConstraint("subject", "client_feedback_id", name="uq_feedback_client_key"),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    # The lookup the rating is about; the migration holds the foreign key to
    # `lookups` (schema "Feedback": `lookupId`).
    lookup_id: Mapped[str] = mapped_column(String(64))
    subject: Mapped[str] = mapped_column(Text)
    # The client's idempotency key; nullable so a deletion can drop it. A reuse
    # with a different rating is a 409 (contract: C-012).
    client_feedback_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    rating: Mapped[str] = mapped_column(Text)
    created_at: Mapped[str] = mapped_column(String(64))


class ReportRow(Base):
    """One reader's report of one lookup (schema "Report")."""

    __tablename__ = "reports"
    __table_args__ = (
        UniqueConstraint("subject", "client_report_id", name="uq_reports_client_key"),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    lookup_id: Mapped[str] = mapped_column(String(64))
    subject: Mapped[str] = mapped_column(Text)
    # The client's idempotency key; nullable so a deletion can drop it
    # (contract: C-013 `clientReportId`).
    client_report_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    reason: Mapped[str] = mapped_column(Text)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(Text)
    created_at: Mapped[str] = mapped_column(String(64))


class ReviewItemRow(Base):
    """One entry queued for a curator to review (schema "ReviewItem")."""

    __tablename__ = "review_items"
    __table_args__ = (
        # One queue item per entry, however many reports it holds (C-014).
        UniqueConstraint("entry_id", name="uq_review_items_entry"),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    entry_id: Mapped[str] = mapped_column(String(64))
    # The clip regenerated for the reporting reader, held on the queue item
    # (schema "ReviewItem": `candidateClipAssetId`); the shared library holds the
    # same candidate on the entry, and the review detail reads it from there.
    candidate_clip_asset_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    state: Mapped[str] = mapped_column(Text)
    # Whether the item's one report-triggered generation has started, so a later
    # report on the entry reuses the candidate instead of paying for a second one
    # (FEAT-011).
    candidate_requested: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[str] = mapped_column(String(64))
    updated_at: Mapped[str] = mapped_column(String(64))
    resolved_at: Mapped[str | None] = mapped_column(String(64), nullable=True)


class ModerationActionRow(Base):
    """One curator action on a library entry (schema "ModerationAction")."""

    __tablename__ = "moderation_actions"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    entry_id: Mapped[str] = mapped_column(String(64))
    report_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    action: Mapped[str] = mapped_column(Text)
    # The clip asset the action makes the one served, when the action is a choose
    # (schema "ModerationAction": `chosenClipAssetId`).
    chosen_clip_asset_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    actor_role: Mapped[str] = mapped_column(Text)
    phrase: Mapped[str | None] = mapped_column(Text, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(String(64))


# Read-only references to tables another service owns. The lookup that served a
# rating or report, and the entry it served, resolve the entry association the
# schema carries by reference rather than by a column on the feedback record
# (schema "Lookup": `servedEntryId`); the library entry resolves the clip a
# curator chose (schema "LibraryEntry": `clipAssetId`, `candidateClipAssetId`).
# They carry their own metadata: the migration owns the tables, and the service
# only reads the columns it needs.
_REFERENCES = MetaData()

LOOKUPS = Table(
    "lookups",
    _REFERENCES,
    Column("id", String(64), primary_key=True),
    Column("served_entry_id", String(64), nullable=True),
)

LIBRARY_ENTRIES = Table(
    "library_entries",
    _REFERENCES,
    Column("id", String(64), primary_key=True),
    Column("clip_asset_id", String(64), nullable=False),
    Column("candidate_clip_asset_id", String(64), nullable=True),
)


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a store call that cannot reach it raises
    the store-unavailable error, so the intake answers 503 and the client retries
    (C-012, C-013) and the review surface answers 503 (C-014 to C-016). The store
    offloads each call to a worker thread, so a slow query never blocks the event
    loop the reader's rating or report runs on (NFR-006). `pool_pre_ping`
    discards a connection the database has dropped, so a failover is transparent
    to the next call rather than a spurious 503.
    """

    return _create_engine(database_url, pool_pre_ping=True)

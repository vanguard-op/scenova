"""Feedback, report, and review-queue persistence (schema "Feedback", "Report").

A rating is recorded against the lookup and, for a word lookup, against the
library entries the clip came from. One reader's rating of a lookup replaces their
earlier rating for the same entry rather than adding to it, so the latest rating
per reader and entry is what the negative-feedback threshold counts. A report is
recorded against the lookup and queues each entry it is about; the queue keeps one
item per entry, so a report on an entry already under review joins the item that is
already there.

Two implementations sit behind one port: the in-memory store the unit tests and a
bare local run use, and the relational store that is the primary database
(architecture.md "Primary Database"). A caller cannot tell them apart. The
relational store derives the entry association from the lookup that served the
rating or report and the queue item's reasons and report ids from the reports
against its entry, because the schema carries those by reference rather than as
columns on the feedback and review-item rows (schema "Feedback", "Report",
"ReviewItem").

A rating and a report are personal data (schema "Feedback", "Report"), so a
data-subject deletion anonymizes the reader's feedback and reports rather than
leaving them beside a live identity (nfr.md "Privacy & Compliance"; analytics.md
"Analytics Data Governance"). The rating, reason, and timestamps survive as usage
evidence, while the identity and the client idempotency keys go.

The curator review surface (C-014 to C-016) reads the same store: the queue, the
reports and negative feedback against an entry, and the moderation actions a
curator records.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Protocol
from uuid import uuid4

from sqlalchemy import and_, func, select, update
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .db import (
    LIBRARY_ENTRIES,
    LOOKUPS,
    FeedbackRow,
    ModerationActionRow,
    ReportRow,
    ReviewItemRow,
)
from .errors import FeedbackStoreUnavailableError
from .models import (
    ChosenClip,
    ModerationActionName,
    Rating,
    ReportReason,
    ReportStatus,
    ReviewState,
)

_NEGATIVE_RATINGS = frozenset({Rating.NOT_HELPFUL, Rating.WRONG})

# The subject an anonymized feedback or report is left under. It is a sentinel no
# reader can hold, so ownership checks can never reattach the record to an
# identity.
ANONYMIZED_SUBJECT = "deleted"


@dataclass(frozen=True)
class FeedbackRecord:
    """One reader's rating of one lookup (schema "Feedback")."""

    id: str
    lookup_id: str
    subject: str
    client_feedback_id: str
    rating: Rating
    # The entries the rating is recorded against; empty for a phrase lookup.
    entry_ids: tuple[str, ...]
    created_at: str


@dataclass(frozen=True)
class ReportRecord:
    """One reader's report of one lookup (schema "Report")."""

    id: str
    lookup_id: str
    subject: str
    client_report_id: str
    reason: ReportReason
    note: str | None
    entry_ids: tuple[str, ...]
    status: ReportStatus
    created_at: str


@dataclass(frozen=True)
class ReviewItem:
    """One entry queued for a curator to review (FEAT-015's queue item).

    An entry reported more than once holds one item with every report against it;
    a repeated negative-feedback threshold adds the feedback reason to the same
    item. A flag from a single negative rating is a separate signal and does not
    by itself create an item, so the queue holds exactly the entries a report or
    the threshold queued.

    `candidate_requested` records that the item's one report-triggered generation
    has been started, so a later report on the same entry reuses that candidate
    rather than paying for a second one (FEAT-011).

    `state` moves the item out of `queued` when a curator acts: `actioned` for a
    recorded decision (a choice of clip or a retirement) and `reviewed` for a
    phrase edit, which regenerates the entry and leaves it under review.
    """

    entry_id: str
    reasons: tuple[str, ...]
    report_ids: tuple[str, ...]
    created_at: str
    updated_at: str
    state: ReviewState = ReviewState.QUEUED
    candidate_requested: bool = False


@dataclass(frozen=True)
class ModerationActionRecord:
    """One curator action on a library entry (schema "ModerationAction")."""

    id: str
    entry_id: str
    report_id: str | None
    action: ModerationActionName
    actor_role: str
    chosen_clip: str | None
    phrase: str | None
    notes: str | None
    created_at: str


class FeedbackStore(Protocol):
    """Port for feedback, report, and review-queue persistence."""

    async def feedback_for_client(
        self, subject: str, client_feedback_id: str
    ) -> FeedbackRecord | None: ...

    async def add_feedback(self, record: FeedbackRecord) -> None: ...

    async def set_entry_rating(self, subject: str, entry_id: str, rating: Rating) -> None: ...

    async def negative_raters(self, entry_id: str) -> int: ...

    async def report_for_client(
        self, subject: str, client_report_id: str
    ) -> ReportRecord | None: ...

    async def add_report(self, record: ReportRecord) -> None: ...

    async def has_reported(self, subject: str, entry_id: str) -> bool: ...

    async def set_flagged(self, entry_id: str, flagged: bool) -> None: ...

    async def is_flagged(self, entry_id: str) -> bool: ...

    async def queue_item(self, entry_id: str) -> ReviewItem | None: ...

    async def save_queue_item(self, item: ReviewItem) -> None: ...

    async def queue_items(self) -> list[ReviewItem]: ...

    async def reports_for_entry(self, entry_id: str) -> list[ReportRecord]: ...

    async def feedback_for_entry(self, entry_id: str) -> list[FeedbackRecord]: ...

    async def set_reports_status(self, entry_id: str, status: ReportStatus) -> None: ...

    async def add_moderation_action(self, action: ModerationActionRecord) -> None: ...

    async def moderation_actions(self) -> list[ModerationActionRecord]: ...

    async def anonymize_subject(self, subject: str) -> int:
        """Strip a subject's identity from their feedback and reports; return the count.

        A rating and a report are personal data (schema "Feedback", "Report"), so
        a data-subject deletion severs the identity and drops the client
        idempotency keys while the rating, reason, and timestamps survive as
        usage evidence (nfr.md "Privacy & Compliance"). Idempotent: a re-run for
        an already anonymized reader finds nothing.
        """
        ...

    async def aclose(self) -> None:
        """Release whatever the store holds open."""
        ...


class InMemoryFeedbackStore:
    """An in-memory feedback store, its idempotency keys, and its review queue."""

    def __init__(self) -> None:
        self._feedback_by_client: dict[tuple[str, str], FeedbackRecord] = {}
        self._report_by_client: dict[tuple[str, str], ReportRecord] = {}
        # The latest rating each reader gave each entry, keyed by reader and
        # entry, so a repeated rating replaces the one before it.
        self._entry_rating: dict[tuple[str, str], Rating] = {}
        # The entries each reader has already reported, so a second report from
        # the same reader is refused rather than queued twice.
        self._reported: set[tuple[str, str]] = set()
        self._flagged: set[str] = set()
        self._queue: dict[str, ReviewItem] = {}
        self._actions: list[ModerationActionRecord] = []

    async def feedback_for_client(
        self, subject: str, client_feedback_id: str
    ) -> FeedbackRecord | None:
        return self._feedback_by_client.get((subject, client_feedback_id))

    async def add_feedback(self, record: FeedbackRecord) -> None:
        self._feedback_by_client[(record.subject, record.client_feedback_id)] = record

    async def set_entry_rating(self, subject: str, entry_id: str, rating: Rating) -> None:
        self._entry_rating[(subject, entry_id)] = rating

    async def negative_raters(self, entry_id: str) -> int:
        return sum(
            1
            for (subject, rated_entry), rating in self._entry_rating.items()
            if rated_entry == entry_id and rating in _NEGATIVE_RATINGS
        )

    async def report_for_client(self, subject: str, client_report_id: str) -> ReportRecord | None:
        return self._report_by_client.get((subject, client_report_id))

    async def add_report(self, record: ReportRecord) -> None:
        self._report_by_client[(record.subject, record.client_report_id)] = record
        for entry_id in record.entry_ids:
            self._reported.add((record.subject, entry_id))

    async def has_reported(self, subject: str, entry_id: str) -> bool:
        return (subject, entry_id) in self._reported

    async def set_flagged(self, entry_id: str, flagged: bool) -> None:
        if flagged:
            self._flagged.add(entry_id)
        else:
            self._flagged.discard(entry_id)

    async def is_flagged(self, entry_id: str) -> bool:
        return entry_id in self._flagged

    async def queue_item(self, entry_id: str) -> ReviewItem | None:
        return self._queue.get(entry_id)

    async def save_queue_item(self, item: ReviewItem) -> None:
        self._queue[item.entry_id] = item

    async def queue_items(self) -> list[ReviewItem]:
        return list(self._queue.values())

    async def reports_for_entry(self, entry_id: str) -> list[ReportRecord]:
        return [
            record for record in self._report_by_client.values() if entry_id in record.entry_ids
        ]

    async def feedback_for_entry(self, entry_id: str) -> list[FeedbackRecord]:
        return [
            record for record in self._feedback_by_client.values() if entry_id in record.entry_ids
        ]

    async def set_reports_status(self, entry_id: str, status: ReportStatus) -> None:
        for key, record in list(self._report_by_client.items()):
            if entry_id not in record.entry_ids:
                continue
            self._report_by_client[key] = replace(record, status=status)

    async def add_moderation_action(self, action: ModerationActionRecord) -> None:
        self._actions.append(action)

    async def moderation_actions(self) -> list[ModerationActionRecord]:
        return list(self._actions)

    async def anonymize_subject(self, subject: str) -> int:
        affected = 0
        for key, record in list(self._feedback_by_client.items()):
            if record.subject != subject:
                continue
            del self._feedback_by_client[key]
            # The idempotency key belonged to the reader who held it, so it is
            # dropped with them rather than left mapped to the record.
            anonymized_feedback = replace(record, subject=ANONYMIZED_SUBJECT, client_feedback_id="")
            self._feedback_by_client[(ANONYMIZED_SUBJECT, "")] = anonymized_feedback
            affected += 1
        for key, report in list(self._report_by_client.items()):
            if report.subject != subject:
                continue
            del self._report_by_client[key]
            anonymized_report = replace(report, subject=ANONYMIZED_SUBJECT, client_report_id="")
            self._report_by_client[(ANONYMIZED_SUBJECT, "")] = anonymized_report
            affected += 1
        # The per-reader rating and the reported set are the reader's own
        # bookkeeping, so they go with the identity.
        for key in list(self._entry_rating):
            if key[0] == subject:
                del self._entry_rating[key]
        self._reported = {(who, entry) for (who, entry) in self._reported if who != subject}
        return affected

    async def aclose(self) -> None:
        return None


def new_feedback_id() -> str:
    return f"fb_{uuid4().hex}"


def new_report_id() -> str:
    return f"rp_{uuid4().hex}"


def new_moderation_action_id() -> str:
    return f"ma_{uuid4().hex}"


def new_queue_item_id() -> str:
    """A queue item's own id, which the schema carries but the queue does not show."""

    return f"ri_{uuid4().hex}"


def new_queue_item(entry_id: str, *, now: str | None = None) -> ReviewItem:
    timestamp = now or _now()
    return ReviewItem(
        entry_id=entry_id,
        reasons=(),
        report_ids=(),
        created_at=timestamp,
        updated_at=timestamp,
    )


def queue_report(
    item: ReviewItem, *, report_id: str, reason: ReportReason, now: str | None = None
) -> ReviewItem:
    """Add a report to a queue item, keeping one item per entry.

    Replaying the same report joins the item it is already on rather than adding
    a second copy, so a retried report is queued once.
    """

    reasons = item.reasons if reason.value in item.reasons else (*item.reasons, reason.value)
    report_ids = item.report_ids if report_id in item.report_ids else (*item.report_ids, report_id)
    return replace(item, reasons=reasons, report_ids=report_ids, updated_at=now or _now())


def queue_feedback(item: ReviewItem, *, now: str | None = None) -> ReviewItem:
    """Queue an entry at the negative-feedback threshold."""

    reasons = (
        item.reasons
        if "feedback_threshold" in item.reasons
        else (*item.reasons, "feedback_threshold")
    )
    return replace(item, reasons=reasons, updated_at=now or _now())


class PostgresFeedbackStore:
    """Feedback, reports, and the review queue in the primary relational database.

    The tables are the platform's migration history (`infra/db/migrations`), so
    the store maps them and never creates them. The entry a rating or report is
    about is reached through the lookup that served it, and a queue item's
    reasons and report ids are read from the reports against its entry, because
    the schema carries those by reference (schema "Feedback", "Report",
    "ReviewItem"). Each call runs its query on a worker thread, so a slow
    database never blocks the event loop the reader's rating or report runs on
    (NFR-006). Every failure to reach the database is reported as the store being
    unavailable, so the intake answers 503 and the client retries (C-012, C-013)
    and the review surface answers 503 (C-014 to C-016).
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def feedback_for_client(
        self, subject: str, client_feedback_id: str
    ) -> FeedbackRecord | None:
        return await asyncio.to_thread(self._feedback_for_client, subject, client_feedback_id)

    async def add_feedback(self, record: FeedbackRecord) -> None:
        await asyncio.to_thread(self._add_feedback, record)

    async def set_entry_rating(self, subject: str, entry_id: str, rating: Rating) -> None:
        # The reader's latest rating of an entry is the feedback row that carries
        # it, joined to the lookup that served the entry; there is no separate row
        # to write, so the rating is already recorded by `add_feedback`.
        return None

    async def negative_raters(self, entry_id: str) -> int:
        return await asyncio.to_thread(self._negative_raters, entry_id)

    async def report_for_client(self, subject: str, client_report_id: str) -> ReportRecord | None:
        return await asyncio.to_thread(self._report_for_client, subject, client_report_id)

    async def add_report(self, record: ReportRecord) -> None:
        await asyncio.to_thread(self._add_report, record)

    async def has_reported(self, subject: str, entry_id: str) -> bool:
        return await asyncio.to_thread(self._has_reported, subject, entry_id)

    async def set_flagged(self, entry_id: str, flagged: bool) -> None:
        # The flag is derived: an entry is flagged while it has a negative rater,
        # which is the feedback rows joined to the lookup that served it. There is
        # no separate flag to store.
        return None

    async def is_flagged(self, entry_id: str) -> bool:
        return await self.negative_raters(entry_id) > 0

    async def queue_item(self, entry_id: str) -> ReviewItem | None:
        return await asyncio.to_thread(self._queue_item, entry_id)

    async def save_queue_item(self, item: ReviewItem) -> None:
        await asyncio.to_thread(self._save_queue_item, item)

    async def queue_items(self) -> list[ReviewItem]:
        return await asyncio.to_thread(self._queue_items)

    async def reports_for_entry(self, entry_id: str) -> list[ReportRecord]:
        return await asyncio.to_thread(self._reports_for_entry, entry_id)

    async def feedback_for_entry(self, entry_id: str) -> list[FeedbackRecord]:
        return await asyncio.to_thread(self._feedback_for_entry, entry_id)

    async def set_reports_status(self, entry_id: str, status: ReportStatus) -> None:
        await asyncio.to_thread(self._set_reports_status, entry_id, status)

    async def add_moderation_action(self, action: ModerationActionRecord) -> None:
        await asyncio.to_thread(self._add_moderation_action, action)

    async def moderation_actions(self) -> list[ModerationActionRecord]:
        return await asyncio.to_thread(self._moderation_actions)

    async def anonymize_subject(self, subject: str) -> int:
        return await asyncio.to_thread(self._anonymize_subject, subject)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    # --- synchronous bodies, each run on a worker thread ----------------------

    def _feedback_for_client(self, subject: str, client_feedback_id: str) -> FeedbackRecord | None:
        try:
            with self._sessions() as session:
                row = session.scalar(
                    select(FeedbackRow).where(
                        FeedbackRow.subject == subject,
                        FeedbackRow.client_feedback_id == client_feedback_id,
                    )
                )
                return None if row is None else _feedback_record(session, row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _add_feedback(self, record: FeedbackRecord) -> None:
        try:
            with self._sessions() as session, session.begin():
                session.add(
                    FeedbackRow(
                        id=record.id,
                        lookup_id=record.lookup_id,
                        subject=record.subject,
                        client_feedback_id=record.client_feedback_id,
                        rating=record.rating.value,
                        created_at=record.created_at,
                    )
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _negative_raters(self, entry_id: str) -> int:
        # Only a reader's latest rating of an entry counts, so the feedback rows
        # for the entry are reduced to the newest per reader before the negative
        # ones are counted (FEAT-010 edge).
        latest = (
            select(FeedbackRow.subject, func.max(FeedbackRow.created_at).label("latest"))
            .join(LOOKUPS, FeedbackRow.lookup_id == LOOKUPS.c.id)
            .where(LOOKUPS.c.served_entry_id == entry_id)
            .group_by(FeedbackRow.subject)
            .subquery()
        )
        statement = (
            select(func.count(func.distinct(FeedbackRow.subject)))
            .join(LOOKUPS, FeedbackRow.lookup_id == LOOKUPS.c.id)
            .join(
                latest,
                and_(
                    FeedbackRow.subject == latest.c.subject,
                    FeedbackRow.created_at == latest.c.latest,
                ),
            )
            .where(
                LOOKUPS.c.served_entry_id == entry_id,
                FeedbackRow.rating.in_([rating.value for rating in _NEGATIVE_RATINGS]),
            )
        )
        try:
            with self._sessions() as session:
                return int(session.scalar(statement) or 0)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _report_for_client(self, subject: str, client_report_id: str) -> ReportRecord | None:
        try:
            with self._sessions() as session:
                row = session.scalar(
                    select(ReportRow).where(
                        ReportRow.subject == subject,
                        ReportRow.client_report_id == client_report_id,
                    )
                )
                if row is None:
                    return None
                return _report_record(row, _served_entry_ids(session, row.lookup_id))
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _add_report(self, record: ReportRecord) -> None:
        try:
            with self._sessions() as session, session.begin():
                session.add(
                    ReportRow(
                        id=record.id,
                        lookup_id=record.lookup_id,
                        subject=record.subject,
                        client_report_id=record.client_report_id,
                        reason=record.reason.value,
                        note=record.note,
                        status=record.status.value,
                        created_at=record.created_at,
                    )
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _has_reported(self, subject: str, entry_id: str) -> bool:
        statement = (
            select(func.count())
            .select_from(ReportRow)
            .join(LOOKUPS, ReportRow.lookup_id == LOOKUPS.c.id)
            .where(
                ReportRow.subject == subject,
                LOOKUPS.c.served_entry_id == entry_id,
            )
        )
        try:
            with self._sessions() as session:
                return int(session.scalar(statement) or 0) > 0
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _queue_item(self, entry_id: str) -> ReviewItem | None:
        try:
            with self._sessions() as session:
                row = session.scalar(
                    select(ReviewItemRow).where(ReviewItemRow.entry_id == entry_id)
                )
                return None if row is None else _review_item(session, row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _save_queue_item(self, item: ReviewItem) -> None:
        try:
            with self._sessions() as session, session.begin():
                row = session.scalar(
                    select(ReviewItemRow).where(ReviewItemRow.entry_id == item.entry_id)
                )
                if row is None:
                    # The queue item's reasons and report ids are not stored; they
                    # are read from the reports against the entry, so a new row
                    # only carries the entry, its state, and its timestamps.
                    row = ReviewItemRow(
                        id=new_queue_item_id(),
                        entry_id=item.entry_id,
                        created_at=item.created_at,
                    )
                    session.add(row)
                row.state = item.state.value
                row.candidate_requested = item.candidate_requested
                row.updated_at = item.updated_at
                # A resolved item records when it was resolved; a queued one has
                # no resolution time.
                row.resolved_at = None if item.state is ReviewState.QUEUED else item.updated_at
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _queue_items(self) -> list[ReviewItem]:
        try:
            with self._sessions() as session:
                rows = session.scalars(select(ReviewItemRow)).all()
                return [_review_item(session, row) for row in rows]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _reports_for_entry(self, entry_id: str) -> list[ReportRecord]:
        try:
            with self._sessions() as session:
                rows = session.scalars(
                    select(ReportRow)
                    .join(LOOKUPS, ReportRow.lookup_id == LOOKUPS.c.id)
                    .where(LOOKUPS.c.served_entry_id == entry_id)
                    .order_by(ReportRow.created_at)
                ).all()
                return [_report_record(row, (entry_id,)) for row in rows]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _feedback_for_entry(self, entry_id: str) -> list[FeedbackRecord]:
        try:
            with self._sessions() as session:
                rows = session.scalars(
                    select(FeedbackRow)
                    .join(LOOKUPS, FeedbackRow.lookup_id == LOOKUPS.c.id)
                    .where(LOOKUPS.c.served_entry_id == entry_id)
                    .order_by(FeedbackRow.created_at)
                ).all()
                return [
                    FeedbackRecord(
                        id=row.id,
                        lookup_id=row.lookup_id,
                        subject=row.subject,
                        client_feedback_id=row.client_feedback_id or "",
                        rating=Rating(row.rating),
                        entry_ids=(entry_id,),
                        created_at=row.created_at,
                    )
                    for row in rows
                ]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _set_reports_status(self, entry_id: str, status: ReportStatus) -> None:
        lookup_ids = select(LOOKUPS.c.id).where(LOOKUPS.c.served_entry_id == entry_id)
        try:
            with self._sessions() as session, session.begin():
                session.execute(
                    update(ReportRow)
                    .where(ReportRow.lookup_id.in_(lookup_ids))
                    .values(status=status.value)
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _add_moderation_action(self, action: ModerationActionRecord) -> None:
        try:
            with self._sessions() as session, session.begin():
                session.add(
                    ModerationActionRow(
                        id=action.id,
                        entry_id=action.entry_id,
                        report_id=action.report_id,
                        action=action.action.value,
                        chosen_clip_asset_id=_chosen_asset_id(
                            session, action.entry_id, action.chosen_clip
                        ),
                        actor_role=action.actor_role,
                        phrase=action.phrase,
                        notes=action.notes,
                        created_at=action.created_at,
                    )
                )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _moderation_actions(self) -> list[ModerationActionRecord]:
        try:
            with self._sessions() as session:
                rows = session.scalars(
                    select(ModerationActionRow).order_by(ModerationActionRow.created_at)
                ).all()
                return [_moderation_action(session, row) for row in rows]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _anonymize_subject(self, subject: str) -> int:
        try:
            with self._sessions() as session, session.begin():
                feedback_rows = session.scalars(
                    select(FeedbackRow).where(FeedbackRow.subject == subject)
                ).all()
                for feedback_row in feedback_rows:
                    feedback_row.subject = ANONYMIZED_SUBJECT
                    feedback_row.client_feedback_id = None
                report_rows = session.scalars(
                    select(ReportRow).where(ReportRow.subject == subject)
                ).all()
                for report_row in report_rows:
                    report_row.subject = ANONYMIZED_SUBJECT
                    report_row.client_report_id = None
                return len(feedback_rows) + len(report_rows)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def _feedback_record(session: Session, row: FeedbackRow) -> FeedbackRecord:
    return FeedbackRecord(
        id=row.id,
        lookup_id=row.lookup_id,
        subject=row.subject,
        client_feedback_id=row.client_feedback_id or "",
        rating=Rating(row.rating),
        entry_ids=_served_entry_ids(session, row.lookup_id),
        created_at=row.created_at,
    )


def _report_record(row: ReportRow, entry_ids: tuple[str, ...]) -> ReportRecord:
    return ReportRecord(
        id=row.id,
        lookup_id=row.lookup_id,
        subject=row.subject,
        client_report_id=row.client_report_id or "",
        reason=ReportReason(row.reason),
        note=row.note,
        entry_ids=entry_ids,
        status=ReportStatus(row.status),
        created_at=row.created_at,
    )


def _served_entry_ids(session: Session, lookup_id: str) -> tuple[str, ...]:
    """The entry a lookup served, reached through the lookup the schema references.

    A lookup carries one `servedEntryId` (schema "Lookup"), so the feedback store
    reads the entry association back as that single reference.
    """

    served: str | None = session.scalar(
        select(LOOKUPS.c.served_entry_id).where(LOOKUPS.c.id == lookup_id)
    )
    return () if served is None else (served,)


def _review_item(session: Session, row: ReviewItemRow) -> ReviewItem:
    reports = session.scalars(
        select(ReportRow)
        .join(LOOKUPS, ReportRow.lookup_id == LOOKUPS.c.id)
        .where(LOOKUPS.c.served_entry_id == row.entry_id)
        .order_by(ReportRow.created_at)
    ).all()
    reasons = tuple(dict.fromkeys(report.reason for report in reports))
    if not reasons:
        # An item with no report against its entry was queued by the
        # negative-feedback threshold (FEAT-010).
        reasons = ("feedback_threshold",)
    return ReviewItem(
        entry_id=row.entry_id,
        reasons=reasons,
        report_ids=tuple(report.id for report in reports),
        created_at=row.created_at,
        updated_at=row.updated_at,
        state=ReviewState(row.state),
        candidate_requested=bool(row.candidate_requested),
    )


def _chosen_asset_id(session: Session, entry_id: str, chosen_clip: str | None) -> str | None:
    """The clip asset a curator's `choose` makes the one served (C-016).

    The action records the symbolic choice (the clip already serving, or the
    candidate regenerated for the reporting reader); the schema records the clip
    asset, so the choice is resolved against the entry it acts on.
    """

    if chosen_clip is None:
        return None
    row = session.execute(
        select(LIBRARY_ENTRIES.c.clip_asset_id, LIBRARY_ENTRIES.c.candidate_clip_asset_id).where(
            LIBRARY_ENTRIES.c.id == entry_id
        )
    ).first()
    if row is None:
        return None
    chosen: str | None = (
        row.clip_asset_id
        if chosen_clip == ChosenClip.SERVING.value
        else row.candidate_clip_asset_id
    )
    return chosen


def _chosen_symbol(session: Session, entry_id: str, asset_id: str | None) -> str | None:
    if asset_id is None:
        return None
    row = session.execute(
        select(LIBRARY_ENTRIES.c.clip_asset_id, LIBRARY_ENTRIES.c.candidate_clip_asset_id).where(
            LIBRARY_ENTRIES.c.id == entry_id
        )
    ).first()
    if row is None:
        return None
    if asset_id == row.candidate_clip_asset_id:
        return ChosenClip.CANDIDATE.value
    if asset_id == row.clip_asset_id:
        return ChosenClip.SERVING.value
    return None


def _moderation_action(session: Session, row: ModerationActionRow) -> ModerationActionRecord:
    return ModerationActionRecord(
        id=row.id,
        entry_id=row.entry_id,
        report_id=row.report_id,
        action=ModerationActionName(row.action),
        actor_role=row.actor_role,
        chosen_clip=_chosen_symbol(session, row.entry_id, row.chosen_clip_asset_id),
        phrase=row.phrase,
        notes=row.notes,
        created_at=row.created_at,
    )


def _unavailable() -> FeedbackStoreUnavailableError:
    return FeedbackStoreUnavailableError("The feedback store is unavailable. Please try again.")


def _now() -> str:
    return datetime.now(UTC).isoformat()

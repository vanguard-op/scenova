"""Feedback, report, and review-queue persistence (schema "Feedback", "Report").

A rating is recorded against the lookup and, for a word lookup, against the
library entries the clip came from. One reader's rating of a lookup replaces their
earlier rating for the same entry rather than adding to it, so the latest rating
per reader and entry is what the negative-feedback threshold counts. A report is
recorded against the lookup and queues each entry it is about; the queue keeps one
item per entry, so a report on an entry already under review joins the item that is
already there.

The store is in memory for the reading phase; Cloud SQL replaces it behind the
same port, holding the same entities, so no caller changes.

The curator review surface (C-014 to C-016) reads the same store: the queue, the
reports and negative feedback against an entry, and the moderation actions a
curator records.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import Protocol
from uuid import uuid4

from .models import ModerationActionName, Rating, ReportReason, ReportStatus, ReviewState

_NEGATIVE_RATINGS = frozenset({Rating.NOT_HELPFUL, Rating.WRONG})


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

    `state` moves the item out of `queued` when a curator acts: `actioned` for a
    recorded decision (clear, hold, retire, replace) and `reviewed` for a phrase
    edit, which regenerates the entry and leaves it under review.
    """

    entry_id: str
    reasons: tuple[str, ...]
    report_ids: tuple[str, ...]
    created_at: str
    updated_at: str
    state: ReviewState = ReviewState.QUEUED


@dataclass(frozen=True)
class ModerationActionRecord:
    """One curator action on a library entry (schema "ModerationAction")."""

    id: str
    entry_id: str
    report_id: str | None
    action: ModerationActionName
    actor_role: str
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


def new_feedback_id() -> str:
    return f"fb_{uuid4().hex}"


def new_report_id() -> str:
    return f"rp_{uuid4().hex}"


def new_moderation_action_id() -> str:
    return f"ma_{uuid4().hex}"


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


def _now() -> str:
    return datetime.now(UTC).isoformat()

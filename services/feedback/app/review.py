"""The curator's review surface: the queue, an entry, and the actions (FEAT-015).

The review console works the entries reader reports (FEAT-011) and repeated
negative feedback (FEAT-010) queued. `queue` lists the entries awaiting review,
newest first, one item per entry however many reports it holds (C-014). `entry`
shows one queued entry with its clip, generation phrase, reports, and negative
feedback, and its review state (C-015). `act` records a curator's clear, hold,
retire, replace, or edit_phrase, moves the entry's library status through C-011,
and resolves or advances the queue item (C-016).

The effects follow the feature doc: `clear` returns the entry to serving, `hold`
withholds it, `retire` stops serving it so the next lookup generates a
replacement, `replace` retires it and regenerates, and `edit_phrase` records the
new phrase and regenerates the entry from it. Every action records a
`ModerationAction` and moves the entry's reports to the matching review state.

The state the contract returns per action follows the console's own flow: clear,
hold, retire, and replace return to the queue and mark the item `actioned`;
`edit_phrase` returns to the entry and marks it `reviewed`, because the
regeneration it starts leaves the entry under review. `expectedState` guards
against two curators acting at once: the second action carries the state the
curator saw and is told the entry has moved (C-016 409).
"""

from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import UTC, datetime

from .config import Settings
from .errors import (
    InvalidRequestError,
    ReviewConflictError,
    ReviewEntryNotFoundError,
    ReviewUnavailableError,
)
from .library import (
    EntryMissingError,
    HttpLibrary,
    LibraryEntryView,
    LibraryPort,
    LibraryUnavailableError,
)
from .models import (
    ActionRequest,
    ActionResponse,
    EntryDetailResponse,
    EntryFeedback,
    EntryReport,
    EntryStatus,
    ModerationActionName,
    QueueItem,
    QueueResponse,
    ReportStatus,
    ReviewClip,
    ReviewEntry,
    ReviewState,
)
from .regeneration import (
    HttpRegenerationTrigger,
    RegenerationTrigger,
    RegenerationUnavailableError,
)
from .store import (
    FeedbackStore,
    ModerationActionRecord,
    ReportRecord,
    ReviewItem,
    new_moderation_action_id,
)

# The queue page size; the console pages a long queue through this (C-014
# `pageCount`). The contract leaves the size to the build.
PAGE_SIZE = 20

# A queue item whose only trigger was repeated negative feedback carries this
# reason rather than a reader report's reason.
FEEDBACK_REASON = "feedback_threshold"

# Where each action leaves the queue item. A phrase edit regenerates the entry
# and stays on the entry screen, so it is `reviewed`; every other action is a
# recorded decision that resolves the item.
_ACTION_STATE = {
    ModerationActionName.CLEAR: ReviewState.ACTIONED,
    ModerationActionName.HOLD: ReviewState.ACTIONED,
    ModerationActionName.RETIRE: ReviewState.ACTIONED,
    ModerationActionName.REPLACE: ReviewState.ACTIONED,
    ModerationActionName.EDIT_PHRASE: ReviewState.REVIEWED,
}


class ReviewService:
    """Serves the curator's queue and records the actions taken on it."""

    def __init__(
        self,
        *,
        store: FeedbackStore,
        library: LibraryPort,
        regeneration: RegenerationTrigger,
        page_size: int = PAGE_SIZE,
    ) -> None:
        self._store = store
        self._library = library
        self._regeneration = regeneration
        self._page_size = max(1, page_size)
        # Serialises the expectedState check and the write, so two curators
        # acting at once cannot both pass the check and both stand.
        self._action_lock = asyncio.Lock()

    async def queue(
        self,
        *,
        reason: str | None,
        state: ReviewState | None,
        word: str | None,
        page: int,
    ) -> QueueResponse:
        """List the entries awaiting review, newest first (C-014)."""

        items = await self._store.queue_items()
        enriched = await self._read_entries(items)

        open_count = sum(1 for _, item in enriched if item.state is not ReviewState.ACTIONED)

        selected = [
            (entry, item)
            for entry, item in enriched
            if _matches(entry, item, reason=reason, state=state, word=word)
        ]
        selected.sort(key=lambda pair: pair[1].updated_at, reverse=True)

        page_count = max(1, (len(selected) + self._page_size - 1) // self._page_size)
        current = min(max(1, page), page_count)
        start = (current - 1) * self._page_size
        window = selected[start : start + self._page_size]

        return QueueResponse(
            items=[
                QueueItem(
                    entryId=entry.entry_id,
                    lemma=entry.lemma,
                    senseLabel=entry.sense_label,
                    reason=await self._reason(item),
                    queuedAt=item.created_at,
                    state=item.state,
                )
                for entry, item in window
            ],
            openCount=open_count,
            page=current,
            pageCount=page_count,
        )

    async def entry(self, entry_id: str) -> EntryDetailResponse:
        """Show one queued entry with its evidence and state (C-015)."""

        item = await self._store.queue_item(entry_id)
        if item is None:
            raise ReviewEntryNotFoundError("No entry is queued for review.")
        entry = await self._read_entry(entry_id)
        reports = await self._reports(entry_id)
        feedback = await self._feedback(entry_id)
        return EntryDetailResponse(
            entry=_entry(entry),
            reports=reports,
            feedback=feedback,
            state=item.state,
        )

    async def act(self, entry_id: str, request: ActionRequest) -> ActionResponse:
        """Record a curator's action and move the entry and its queue item (C-016)."""

        async with self._action_lock:
            item = await self._store.queue_item(entry_id)
            if item is None:
                raise ReviewEntryNotFoundError("No entry is queued for review.")
            entry = await self._read_entry(entry_id)
            if item.state is not request.expectedState:
                raise ReviewConflictError("The entry has already moved since you saw it.")
            phrase = _validated_phrase(request)

            reports = await self._store.reports_for_entry(entry_id)
            action = ModerationActionRecord(
                id=new_moderation_action_id(),
                entry_id=entry_id,
                report_id=_newest_report_id(reports),
                action=request.action,
                actor_role="curator",
                phrase=phrase,
                notes=request.notes,
                created_at=_now(),
            )
            await self._store.add_moderation_action(action)

            status = await self._apply(request.action, entry, phrase)
            state = _ACTION_STATE[request.action]
            await self._store.save_queue_item(replace(item, state=state, updated_at=_now()))
            await self._store.set_reports_status(
                entry_id,
                ReportStatus.ACTIONED if state is ReviewState.ACTIONED else ReportStatus.REVIEWED,
            )
            return ActionResponse(
                actionId=action.id,
                entryId=entry_id,
                status=status,
                state=state,
            )

    async def aclose(self) -> None:
        """Release the library and generation clients' connections."""

        await self._library.aclose()
        await self._regeneration.aclose()

    async def _apply(
        self,
        action: ModerationActionName,
        entry: LibraryEntryView,
        phrase: str | None,
    ) -> EntryStatus:
        """Move the entry's library status and start any regeneration."""

        if action is ModerationActionName.CLEAR:
            await self._set_status(entry.entry_id, EntryStatus.ACTIVE)
            return EntryStatus.ACTIVE
        if action is ModerationActionName.HOLD:
            await self._set_status(entry.entry_id, EntryStatus.HELD)
            return EntryStatus.HELD

        # retire, replace, and edit_phrase all stop the old clip serving; the
        # replacement is generated from the phrase (a fresh one for replace, the
        # curator's for an edit).
        await self._set_status(entry.entry_id, EntryStatus.RETIRED)
        regeneration_phrase = phrase if action is ModerationActionName.EDIT_PHRASE else None
        if action in (ModerationActionName.REPLACE, ModerationActionName.EDIT_PHRASE):
            try:
                await self._regeneration.regenerate(
                    entry_id=entry.entry_id,
                    lemma=entry.lemma,
                    sense_label=entry.sense_label,
                    part_of_speech=entry.part_of_speech,
                    phrase=regeneration_phrase,
                )
            except RegenerationUnavailableError as exc:
                raise ReviewUnavailableError(
                    "The review service is unavailable. Please try again."
                ) from exc
        return EntryStatus.RETIRED

    async def _set_status(self, entry_id: str, status: EntryStatus) -> None:
        try:
            await self._library.set_status(entry_id, status.value)
        except EntryMissingError as exc:
            raise ReviewEntryNotFoundError("The library holds no such entry.") from exc
        except LibraryUnavailableError as exc:
            raise ReviewUnavailableError(
                "The review service is unavailable. Please try again."
            ) from exc

    async def _read_entries(
        self, items: list[ReviewItem]
    ) -> list[tuple[LibraryEntryView, ReviewItem]]:
        """Pair each queue item with its library entry, dropping missing entries.

        An entry that no longer exists was superseded by a regeneration, so its
        queue item cannot be worked and is left out of the queue.
        """

        pairs: list[tuple[LibraryEntryView, ReviewItem]] = []
        for item in items:
            entry = await self._read_entry_or_none(item.entry_id)
            if entry is not None:
                pairs.append((entry, item))
        return pairs

    async def _read_entry(self, entry_id: str) -> LibraryEntryView:
        entry = await self._read_entry_or_none(entry_id)
        if entry is None:
            raise ReviewEntryNotFoundError("The library holds no such entry.")
        return entry

    async def _read_entry_or_none(self, entry_id: str) -> LibraryEntryView | None:
        try:
            return await self._library.get_entry(entry_id)
        except LibraryUnavailableError as exc:
            raise ReviewUnavailableError(
                "The review service is unavailable. Please try again."
            ) from exc

    async def _reason(self, item: ReviewItem) -> str:
        reports = await self._store.reports_for_entry(item.entry_id)
        newest = _newest_report(reports)
        if newest is not None:
            return newest.reason.value
        if FEEDBACK_REASON in item.reasons:
            return FEEDBACK_REASON
        return item.reasons[-1] if item.reasons else FEEDBACK_REASON

    async def _reports(self, entry_id: str) -> list[EntryReport]:
        reports = await self._store.reports_for_entry(entry_id)
        reports.sort(key=lambda record: record.created_at, reverse=True)
        return [
            EntryReport(
                reportId=record.id,
                reason=record.reason.value,
                note=record.note,
                createdAt=record.created_at,
            )
            for record in reports
        ]

    async def _feedback(self, entry_id: str) -> list[EntryFeedback]:
        records = await self._store.feedback_for_entry(entry_id)
        negative = [record for record in records if record.rating.value in ("not_helpful", "wrong")]
        negative.sort(key=lambda record: record.created_at, reverse=True)
        return [
            EntryFeedback(rating=record.rating, createdAt=record.created_at) for record in negative
        ]


def _matches(
    entry: LibraryEntryView,
    item: ReviewItem,
    *,
    reason: str | None,
    state: ReviewState | None,
    word: str | None,
) -> bool:
    if reason is not None and reason not in item.reasons:
        return False
    if state is not None and item.state is not state:
        return False
    return word is None or entry.lemma.casefold() == word.strip().casefold()


def _validated_phrase(request: ActionRequest) -> str | None:
    if request.action is not ModerationActionName.EDIT_PHRASE:
        return None
    phrase = (request.phrase or "").strip()
    if not phrase:
        raise InvalidRequestError("A phrase edit needs the new generation phrase.")
    return phrase


def _newest_report(reports: list[ReportRecord]) -> ReportRecord | None:
    if not reports:
        return None
    return max(reports, key=lambda record: record.created_at)


def _newest_report_id(reports: list[ReportRecord]) -> str | None:
    newest = _newest_report(reports)
    return None if newest is None else newest.id


def _entry(entry: LibraryEntryView) -> ReviewEntry:
    return ReviewEntry(
        entryId=entry.entry_id,
        lemma=entry.lemma,
        senseLabel=entry.sense_label,
        glossPhrase=entry.gloss_phrase,
        status=EntryStatus(entry.status),
        clip=ReviewClip(
            url=entry.clip_url,
            durationSeconds=entry.clip_duration_seconds,
            resolution=entry.clip_resolution,
            hasAudio=entry.clip_has_audio,
        ),
    )


def _now() -> str:
    return datetime.now(UTC).isoformat()


def build_default_review_service(settings: Settings, store: FeedbackStore) -> ReviewService:
    """Build the review service on the intake's store, library, and pipeline.

    The review queue is the same store the intake queues reports and feedback on,
    so a report recorded through C-013 is immediately visible to a curator.
    """

    return ReviewService(
        store=store,
        library=HttpLibrary(
            base_url=settings.library_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.library_timeout_seconds,
        ),
        regeneration=HttpRegenerationTrigger(
            base_url=settings.pipeline_base_url,
            internal_audience=settings.internal_audience,
            clip_model_pin=settings.clip_model_pin,
            timeout_seconds=settings.pipeline_timeout_seconds,
        ),
    )

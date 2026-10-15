"""The curator's review surface: the queue, an entry, and the actions (FEAT-015).

The review console works the entries reader reports (FEAT-011) and repeated
negative feedback (FEAT-010) queued. `queue` lists the entries awaiting review,
newest first, one item per entry however many reports it holds (C-014). `entry`
shows one queued entry with the clip it serves beside the candidate regenerated
for the reporting reader, its generation phrase, reports, and negative feedback,
and its review state (C-015). `act` records a curator's choice of clip, a
retirement, or a phrase edit and resolves or advances the queue item (C-016).

The effects follow the feature doc: `choose` makes the named clip the one served
to every reader — the clip already serving, or the candidate regenerated for the
reporting reader; `retire` stops serving the entry, and the next lookup generates
a replacement; `edit_phrase` records the new phrase and regenerates the entry
from it. Until a `choose` or a `retire`, the entry keeps serving the clip it
already serves. Every action records a `ModerationAction`.

`edit_phrase` returns the item to the entry screen and marks it `reviewed`,
because the regeneration it starts leaves the entry under review; every other
action resolves the item and marks it `actioned`. `expectedState` guards against
two curators acting at once: the second action carries the state the curator saw
and is told the entry has moved (C-016 409).
"""

from __future__ import annotations

import asyncio
from dataclasses import replace
from datetime import UTC, datetime

from .config import Settings
from .errors import (
    FeedbackStoreUnavailableError,
    InvalidRequestError,
    ReviewConflictError,
    ReviewEntryNotFoundError,
    ReviewUnavailableError,
)
from .library import (
    EntryMissingError,
    HttpLibrary,
    LibraryClipView,
    LibraryEntryView,
    LibraryPort,
    LibraryUnavailableError,
)
from .models import (
    ActionRequest,
    ActionResponse,
    ChosenClip,
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
# and stays on the entry screen, so it is `reviewed`; a choice or a retirement is
# a recorded decision that resolves the item.
_ACTION_STATE = {
    ModerationActionName.CHOOSE: ReviewState.ACTIONED,
    ModerationActionName.RETIRE: ReviewState.ACTIONED,
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

        try:
            return await self._queue(reason=reason, state=state, word=word, page=page)
        except FeedbackStoreUnavailableError as exc:
            raise ReviewUnavailableError(
                "The review service is unavailable. Please try again."
            ) from exc

    async def _queue(
        self,
        *,
        reason: str | None,
        state: ReviewState | None,
        word: str | None,
        page: int,
    ) -> QueueResponse:
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
        """Show one queued entry with its candidate, evidence, and state (C-015)."""

        try:
            return await self._entry(entry_id)
        except FeedbackStoreUnavailableError as exc:
            raise ReviewUnavailableError(
                "The review service is unavailable. Please try again."
            ) from exc

    async def _entry(self, entry_id: str) -> EntryDetailResponse:
        item = await self._store.queue_item(entry_id)
        if item is None:
            raise ReviewEntryNotFoundError("No entry is queued for review.")
        entry = await self._read_entry(entry_id)
        candidate = await self._read_candidate(entry_id)
        reports = await self._reports(entry_id)
        feedback = await self._feedback(entry_id)
        return EntryDetailResponse(
            entry=_entry(entry),
            candidate=_clip(candidate) if candidate is not None else None,
            reports=reports,
            feedback=feedback,
            state=item.state,
        )

    async def act(self, entry_id: str, request: ActionRequest) -> ActionResponse:
        """Record a curator's action and move the entry and its queue item (C-016)."""

        try:
            return await self._act(entry_id, request)
        except FeedbackStoreUnavailableError as exc:
            raise ReviewUnavailableError(
                "The review service is unavailable. Please try again."
            ) from exc

    async def _act(self, entry_id: str, request: ActionRequest) -> ActionResponse:
        async with self._action_lock:
            item = await self._store.queue_item(entry_id)
            if item is None:
                raise ReviewEntryNotFoundError("No entry is queued for review.")
            entry = await self._read_entry(entry_id)
            if item.state is not request.expectedState:
                raise ReviewConflictError("The entry has already moved since you saw it.")
            chosen_clip, phrase = _validated(request)

            reports = await self._store.reports_for_entry(entry_id)
            action = ModerationActionRecord(
                id=new_moderation_action_id(),
                entry_id=entry_id,
                report_id=_newest_report_id(reports),
                action=request.action,
                actor_role="curator",
                chosen_clip=None if chosen_clip is None else chosen_clip.value,
                phrase=phrase,
                notes=request.notes,
                created_at=_now(),
            )
            await self._store.add_moderation_action(action)

            status = await self._apply(request.action, entry, chosen_clip, phrase)
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
        chosen_clip: ChosenClip | None,
        phrase: str | None,
    ) -> EntryStatus:
        """Move the entry's library status and start any regeneration."""

        if action is ModerationActionName.CHOOSE:
            # The entry already serves its clip, so choosing the serving clip
            # changes nothing; choosing the candidate makes it the serving clip
            # for every reader from now on (FEAT-015).
            if chosen_clip is ChosenClip.CANDIDATE:
                await self._promote_candidate(entry.entry_id)
            return EntryStatus.ACTIVE

        if action is ModerationActionName.RETIRE:
            # Retiring stops the entry serving; the replacement is left to the
            # next lookup of the word.
            await self._set_status(entry.entry_id, EntryStatus.RETIRED)
            return EntryStatus.RETIRED

        # edit_phrase: retire the old clip and regenerate the entry from the
        # curator's phrase, so the entry comes back under review.
        await self._set_status(entry.entry_id, EntryStatus.RETIRED)
        try:
            await self._regeneration.regenerate(
                entry_id=entry.entry_id,
                lemma=entry.lemma,
                sense_label=entry.sense_label,
                part_of_speech=entry.part_of_speech,
                phrase=phrase,
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

    async def _promote_candidate(self, entry_id: str) -> None:
        try:
            await self._library.promote_candidate(entry_id)
        except EntryMissingError as exc:
            # There is no candidate to choose; the curator cannot choose a clip
            # the entry does not hold.
            raise InvalidRequestError("No candidate clip is held for this entry.") from exc
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

    async def _read_candidate(self, entry_id: str) -> LibraryClipView | None:
        try:
            return await self._library.get_candidate(entry_id)
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


def _validated(request: ActionRequest) -> tuple[ChosenClip | None, str | None]:
    """Validate an action's own requirements, or refuse it (C-016 400)."""

    if request.action is ModerationActionName.CHOOSE:
        if request.chosenClip is None:
            raise InvalidRequestError("A choose action needs the clip to serve.")
        return request.chosenClip, None

    if request.action is ModerationActionName.EDIT_PHRASE:
        phrase = (request.phrase or "").strip()
        if not phrase:
            raise InvalidRequestError("A phrase edit needs the new generation phrase.")
        return None, phrase

    return None, None


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
        clip=_clip(entry.clip),
    )


def _clip(clip: LibraryClipView) -> ReviewClip:
    return ReviewClip(
        url=clip.url,
        durationSeconds=clip.duration_seconds,
        resolution=clip.resolution,
        hasAudio=clip.has_audio,
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

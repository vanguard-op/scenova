"""Ratings and reports: recorded, queued, and held (FEAT-010, FEAT-011).

`record_feedback` records a reader's rating of a clip (C-012). The rating is
recorded against the lookup and, for a word lookup, against the library entries
the clip came from; a repeated rating replaces the reader's earlier one. A
negative rating flags the entry, and when enough readers' latest ratings are
negative the entry is queued for a curator to review. A rating on a phrase lookup
is recorded against the lookup alone and never touches the shared library.

`record_report` records a reader's report of a clip (C-013). The report opens a
queue item for the entry, or joins the one already open, and starts one
generation for the entry: the pipeline holds the fresh clip as the entry's
candidate and serves it to the reporting reader, while the entry keeps serving
the clip it already serves to everyone else until a curator decides (FEAT-011).
A second report of the same entry from one reader is refused; a report on a
phrase lookup is recorded against the lookup and has no shared effect, because a
phrase clip is never in the shared library.

Both are idempotent on the client's key, so a report or rating made offline and
resent when the connection returns is recorded once.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import replace
from datetime import UTC, datetime

from .config import Settings
from .errors import (
    AlreadyReportedError,
    ClientFeedbackIdConflictError,
    ClientReportIdConflictError,
    FeedbackStoreUnavailableError,
    LookupNotFoundError,
    NoClipServedError,
)
from .library import HttpLibrary, LibraryPort, LibraryUnavailableError
from .lookups import HttpLookupDirectory, LookupDirectory, LookupRecord, LookupUnavailableError
from .models import (
    FeedbackRequest,
    FeedbackResponse,
    LookupKind,
    LookupStatus,
    ReportRequest,
    ReportResponse,
    ReportStatus,
)
from .regeneration import (
    HttpRegenerationTrigger,
    RegenerationTrigger,
    RegenerationUnavailableError,
)
from .store import (
    FeedbackRecord,
    FeedbackStore,
    InMemoryFeedbackStore,
    ReportRecord,
    ReviewItem,
    new_feedback_id,
    new_queue_item,
    new_report_id,
    queue_feedback,
    queue_report,
)

logger = logging.getLogger(__name__)

# A phrase lookup that resolved without a clip has nothing for the reader to rate
# or report. A phrase clip is delivered by the clip-ready notice, never on the
# lookup response, so a phrase lookup still generating is accepted: the server
# cannot see the notice, and the contract records phrase feedback against the
# lookup with no shared effect.
_PHRASE_WITHOUT_CLIP = frozenset({LookupStatus.DENIED, LookupStatus.FALLBACK, LookupStatus.EMPTY})


class FeedbackService:
    """Records clip ratings and reports, and queues the entries they flag."""

    def __init__(
        self,
        *,
        store: FeedbackStore,
        lookups: LookupDirectory,
        library: LibraryPort,
        pipeline: RegenerationTrigger,
        negative_feedback_threshold: int,
    ) -> None:
        self._store = store
        self._lookups = lookups
        self._library = library
        self._pipeline = pipeline
        self._threshold = max(1, negative_feedback_threshold)
        # Serialises the idempotency check and the write, so a duplicate client
        # key is replayed rather than recorded twice.
        self._write_lock = asyncio.Lock()

    async def record_feedback(self, request: FeedbackRequest, subject: str) -> FeedbackResponse:
        async with self._write_lock:
            existing = await self._store.feedback_for_client(subject, request.clientFeedbackId)
            if existing is not None:
                if existing.rating is not request.rating or existing.lookup_id != request.lookupId:
                    raise ClientFeedbackIdConflictError(
                        "This clientFeedbackId was already used with a different rating."
                    )
                return FeedbackResponse(recorded=True)

            record = await self._read_lookup(request.lookupId, subject)
            feedback = FeedbackRecord(
                id=new_feedback_id(),
                lookup_id=request.lookupId,
                subject=subject,
                client_feedback_id=request.clientFeedbackId,
                rating=request.rating,
                entry_ids=record.served_entry_ids,
                created_at=_now(),
            )
            await self._store.add_feedback(feedback)
            for entry_id in record.served_entry_ids:
                await self._store.set_entry_rating(subject, entry_id, request.rating)
                await self._refresh_entry(entry_id)
        return FeedbackResponse(recorded=True)

    async def record_report(self, request: ReportRequest, subject: str) -> ReportResponse:
        async with self._write_lock:
            existing = await self._store.report_for_client(subject, request.clientReportId)
            if existing is not None:
                if (
                    existing.lookup_id != request.lookupId
                    or existing.reason is not request.reason
                    or existing.note != request.note
                ):
                    raise ClientReportIdConflictError(
                        "This clientReportId was already used with a different report."
                    )
                return ReportResponse(reportId=existing.id, state=existing.status)

            record = await self._read_lookup(request.lookupId, subject)
            for entry_id in record.served_entry_ids:
                if await self._store.has_reported(subject, entry_id):
                    raise AlreadyReportedError("You have already reported this clip.")

            report = ReportRecord(
                id=new_report_id(),
                lookup_id=request.lookupId,
                subject=subject,
                client_report_id=request.clientReportId,
                reason=request.reason,
                note=request.note,
                entry_ids=record.served_entry_ids,
                status=ReportStatus.QUEUED,
                created_at=_now(),
            )
            await self._store.add_report(report)
            for entry_id in record.served_entry_ids:
                item = await self._queue_item(entry_id)
                item = queue_report(item, report_id=report.id, reason=report.reason)
                await self._store.save_queue_item(item)
                await self._start_candidate(entry_id, item, reader_lookup_id=request.lookupId)
        return ReportResponse(reportId=report.id, state=report.status)

    async def aclose(self) -> None:
        """Release the lookup, library, and pipeline clients' connections."""

        await self._lookups.aclose()
        await self._library.aclose()
        await self._pipeline.aclose()

    async def _read_lookup(self, lookup_id: str, subject: str) -> LookupRecord:
        """Read the lookup, or fail with the contract's 404 / 400 / 503."""

        try:
            record = await self._lookups.read(lookup_id, subject)
        except LookupUnavailableError as exc:
            raise FeedbackStoreUnavailableError(
                "The feedback store is unavailable. Please try again."
            ) from exc
        if record is None:
            raise LookupNotFoundError("No lookup was found for this id.")
        _require_served_clip(record)
        return record

    async def _refresh_entry(self, entry_id: str) -> None:
        """Recompute an entry's flag and queue state after a rating.

        A negative rating flags the entry for review; the entry is queued once
        enough readers' latest ratings are negative (FEAT-010). A reader who later
        rates it helpful clears their own flag, since only the latest rating
        counts, so the flag is recomputed on every rating.
        """

        negative_count = await self._store.negative_raters(entry_id)
        await self._store.set_flagged(entry_id, negative_count > 0)
        if negative_count < self._threshold:
            return
        item = await self._queue_item(entry_id)
        await self._store.save_queue_item(queue_feedback(item))

    async def _start_candidate(
        self, entry_id: str, item: ReviewItem, *, reader_lookup_id: str
    ) -> None:
        """Start the item's one report-triggered generation, if it has not run.

        The candidate generation is a secondary effect of the report: the report
        and its queue item stand whether or not the pipeline can be reached, and a
        later report retries the generation. One generation per item keeps the
        spend to one however many readers report the entry (FEAT-011).
        """

        if item.candidate_requested:
            return
        try:
            entry = await self._library.get_entry(entry_id)
        except LibraryUnavailableError:
            logger.warning(
                "the shared library was unreachable; no candidate was started for entry %s",
                entry_id,
            )
            return
        if entry is None:
            # The entry was superseded before the report reached us; there is
            # nothing left to regenerate a candidate for.
            return
        try:
            await self._pipeline.generate_candidate(
                entry_id=entry_id,
                reader_lookup_id=reader_lookup_id,
                lemma=entry.lemma,
                sense_label=entry.sense_label,
                part_of_speech=entry.part_of_speech,
                nonce=item.created_at,
            )
        except RegenerationUnavailableError:
            logger.warning(
                "the generation pipeline could not start a candidate for entry %s",
                entry_id,
            )
            return
        await self._store.save_queue_item(replace(item, candidate_requested=True))

    async def _queue_item(self, entry_id: str) -> ReviewItem:
        existing = await self._store.queue_item(entry_id)
        return existing if existing is not None else new_queue_item(entry_id)


def build_default_service(
    settings: Settings, store: FeedbackStore | None = None
) -> FeedbackService:
    """Build the service with its store, lookup reader, library, and pipeline."""

    return FeedbackService(
        store=store if store is not None else InMemoryFeedbackStore(),
        lookups=HttpLookupDirectory(
            base_url=settings.lookup_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.lookup_timeout_seconds,
        ),
        library=HttpLibrary(
            base_url=settings.library_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.library_timeout_seconds,
        ),
        pipeline=HttpRegenerationTrigger(
            base_url=settings.pipeline_base_url,
            internal_audience=settings.internal_audience,
            clip_model_pin=settings.clip_model_pin,
            timeout_seconds=settings.pipeline_timeout_seconds,
        ),
        negative_feedback_threshold=settings.negative_feedback_threshold,
    )


def _require_served_clip(record: LookupRecord) -> None:
    """Refuse a lookup that never put a clip in front of the reader."""

    if record.kind is LookupKind.WORD:
        if not record.served_entry_ids:
            raise NoClipServedError("No clip was served for this lookup.")
        return
    if record.status in _PHRASE_WITHOUT_CLIP:
        raise NoClipServedError("No clip was served for this lookup.")


def _now() -> str:
    return datetime.now(UTC).isoformat()

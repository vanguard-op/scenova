"""Service tests for ratings and reports: recorded, queued, and held.

These drive the service directly, so the review queue and the flag a negative
rating leaves are observable without a wire contract for them.
"""

from __future__ import annotations

import pytest

from feedback.app.errors import (
    AlreadyReportedError,
    ClientFeedbackIdConflictError,
    ClientReportIdConflictError,
    FeedbackStoreUnavailableError,
    LookupNotFoundError,
    NoClipServedError,
)
from feedback.app.models import (
    FeedbackRequest,
    LookupStatus,
    RatingChoice,
    ReportReason,
    ReportRequest,
    ReportStatus,
)
from feedback.tests.fakes import SUBJECT, entry_view, phrase_lookup, rig, word_lookup


def _rating(
    *, lookup_id: str = "lk_1", rating: RatingChoice = RatingChoice.HELPFUL, client_id: str = "cf_1"
) -> FeedbackRequest:
    return FeedbackRequest(lookupId=lookup_id, rating=rating, clientFeedbackId=client_id)


def _report(
    *,
    lookup_id: str = "lk_1",
    reason: ReportReason = ReportReason.WRONG_MEANING,
    note: str | None = None,
    client_id: str = "cr_1",
) -> ReportRequest:
    return ReportRequest(lookupId=lookup_id, reason=reason, note=note, clientReportId=client_id)


# --- FEAT-010: ratings --------------------------------------------------------


@pytest.mark.asyncio
async def test_a_helpful_rating_is_recorded_against_the_entry() -> None:
    rigged = rig(word_lookup())

    response = await rigged.service.record_feedback(_rating(), SUBJECT)

    assert response.recorded is True
    stored = await rigged.store.feedback_for_client(SUBJECT, "cf_1")
    assert stored is not None and stored.entry_ids == ("le_1",)
    assert await rigged.store.is_flagged("le_1") is False
    assert await rigged.store.queue_items() == []


@pytest.mark.asyncio
async def test_a_negative_rating_flags_the_entry_below_the_threshold() -> None:
    rigged = rig(word_lookup(), threshold=3)

    await rigged.service.record_feedback(_rating(rating=RatingChoice.NOT_HELPFUL), SUBJECT)

    assert await rigged.store.is_flagged("le_1") is True
    # A single flag is not yet a queue item; only the threshold queues it.
    assert await rigged.store.queue_items() == []


@pytest.mark.asyncio
async def test_the_threshold_queues_the_entry_for_review() -> None:
    rigged = rig(word_lookup(subjects=("reader-1", "reader-2")), threshold=2)

    await rigged.service.record_feedback(
        _rating(rating=RatingChoice.NOT_HELPFUL, client_id="cf_1"), "reader-1"
    )
    await rigged.service.record_feedback(
        _rating(rating=RatingChoice.NOT_HELPFUL, client_id="cf_2"), "reader-2"
    )

    item = await rigged.store.queue_item("le_1")
    assert item is not None
    assert "feedback_threshold" in item.reasons


@pytest.mark.asyncio
async def test_a_repeated_rating_replaces_the_readers_latest() -> None:
    # FEAT-010 edge: repeated feedback from one reader counts only its latest, so
    # a reader who changes to helpful no longer counts against the entry.
    rigged = rig(word_lookup(), threshold=2)

    await rigged.service.record_feedback(
        _rating(rating=RatingChoice.NOT_HELPFUL, client_id="cf_1"), SUBJECT
    )
    await rigged.service.record_feedback(
        _rating(rating=RatingChoice.HELPFUL, client_id="cf_2"), SUBJECT
    )

    assert await rigged.store.negative_raters("le_1") == 0
    assert await rigged.store.is_flagged("le_1") is False
    assert await rigged.store.queue_items() == []


@pytest.mark.asyncio
async def test_a_phrase_rating_never_touches_the_shared_library() -> None:
    rigged = rig(phrase_lookup())

    response = await rigged.service.record_feedback(_rating(), SUBJECT)

    assert response.recorded is True
    stored = await rigged.store.feedback_for_client(SUBJECT, "cf_1")
    assert stored is not None and stored.entry_ids == ()
    assert await rigged.store.queue_items() == []


@pytest.mark.asyncio
async def test_a_replayed_rating_is_recorded_once() -> None:
    rigged = rig(word_lookup())

    first = await rigged.service.record_feedback(_rating(), SUBJECT)
    second = await rigged.service.record_feedback(_rating(), SUBJECT)

    assert first.recorded is True and second.recorded is True
    assert len(rigged.store._feedback_by_client) == 1


@pytest.mark.asyncio
async def test_a_reused_key_with_a_different_rating_conflicts() -> None:
    rigged = rig(word_lookup())
    await rigged.service.record_feedback(_rating(), SUBJECT)

    with pytest.raises(ClientFeedbackIdConflictError):
        await rigged.service.record_feedback(_rating(rating=RatingChoice.NOT_HELPFUL), SUBJECT)


@pytest.mark.asyncio
async def test_an_unknown_lookup_is_not_found() -> None:
    rigged = rig()

    with pytest.raises(LookupNotFoundError):
        await rigged.service.record_feedback(_rating(), SUBJECT)


@pytest.mark.asyncio
async def test_a_word_lookup_without_a_served_clip_is_refused() -> None:
    rigged = rig(word_lookup(entries=(), status=LookupStatus.GENERATING))

    with pytest.raises(NoClipServedError):
        await rigged.service.record_feedback(_rating(), SUBJECT)


@pytest.mark.asyncio
async def test_a_denied_phrase_lookup_is_refused() -> None:
    rigged = rig(phrase_lookup(status=LookupStatus.DENIED))

    with pytest.raises(NoClipServedError):
        await rigged.service.record_feedback(_rating(), SUBJECT)


@pytest.mark.asyncio
async def test_a_lookup_service_outage_reports_the_store_unavailable() -> None:
    rigged = rig(word_lookup(), lookup_unavailable=True)

    with pytest.raises(FeedbackStoreUnavailableError):
        await rigged.service.record_feedback(_rating(), SUBJECT)


# --- FEAT-011: reports --------------------------------------------------------


@pytest.mark.asyncio
async def test_a_report_queues_the_entry_and_starts_one_candidate() -> None:
    rigged = rig(word_lookup(), entries={"le_1": entry_view()})

    response = await rigged.service.record_report(_report(), SUBJECT)

    assert response.reportId.startswith("rp_")
    assert response.state is ReportStatus.QUEUED
    item = await rigged.store.queue_item("le_1")
    assert item is not None
    assert "wrong_meaning" in item.reasons
    assert item.report_ids == (response.reportId,)
    assert item.candidate_requested is True
    # The report starts one candidate generation for the entry, carrying the
    # reporting reader's lookup so the fresh clip reaches them (FEAT-011).
    assert rigged.pipeline.candidates == [("le_1", "lk_1", item.created_at)]
    # The entry keeps serving: no status is moved on a report.
    assert rigged.library.statuses == []


@pytest.mark.asyncio
async def test_a_second_report_from_one_reader_is_refused() -> None:
    rigged = rig(word_lookup(), entries={"le_1": entry_view()})
    await rigged.service.record_report(_report(client_id="cr_1"), SUBJECT)

    with pytest.raises(AlreadyReportedError):
        await rigged.service.record_report(_report(client_id="cr_2"), SUBJECT)


@pytest.mark.asyncio
async def test_reports_from_two_readers_share_one_item_and_one_candidate() -> None:
    rigged = rig(
        word_lookup(subjects=("reader-1", "reader-2")),
        entries={"le_1": entry_view()},
    )

    first = await rigged.service.record_report(_report(client_id="cr_1"), "reader-1")
    second = await rigged.service.record_report(
        _report(reason=ReportReason.OFFENSIVE, client_id="cr_2"), "reader-2"
    )

    items = await rigged.store.queue_items()
    assert len(items) == 1
    assert set(items[0].report_ids) == {first.reportId, second.reportId}
    assert {"wrong_meaning", "offensive"} <= set(items[0].reasons)
    # One item, so one candidate: the second report reuses the first's (FEAT-011).
    assert len(rigged.pipeline.candidates) == 1


@pytest.mark.asyncio
async def test_a_replayed_report_is_not_queued_twice() -> None:
    rigged = rig(word_lookup(), entries={"le_1": entry_view()})

    first = await rigged.service.record_report(_report(), SUBJECT)
    second = await rigged.service.record_report(_report(), SUBJECT)

    assert second.reportId == first.reportId
    assert len(rigged.store._report_by_client) == 1
    assert len(rigged.pipeline.candidates) == 1


@pytest.mark.asyncio
async def test_a_reused_report_key_with_a_different_report_conflicts() -> None:
    rigged = rig(word_lookup(), entries={"le_1": entry_view()})
    await rigged.service.record_report(_report(), SUBJECT)

    with pytest.raises(ClientReportIdConflictError):
        await rigged.service.record_report(_report(reason=ReportReason.OTHER), SUBJECT)


@pytest.mark.asyncio
async def test_a_phrase_report_has_no_shared_effect() -> None:
    rigged = rig(phrase_lookup())

    response = await rigged.service.record_report(_report(), SUBJECT)

    assert response.state is ReportStatus.QUEUED
    assert rigged.pipeline.candidates == []
    assert await rigged.store.queue_items() == []


@pytest.mark.asyncio
async def test_a_report_survives_an_unreachable_pipeline_and_retries_the_candidate() -> None:
    # The candidate generation is a secondary effect: an unreachable pipeline
    # leaves the report and its queue item standing, and a later report starts
    # the candidate that never went out (FEAT-011).
    rigged = rig(
        word_lookup(subjects=("reader-1", "reader-2")),
        entries={"le_1": entry_view()},
        pipeline_unavailable=True,
    )

    response = await rigged.service.record_report(_report(client_id="cr_1"), "reader-1")

    assert response.state is ReportStatus.QUEUED
    assert len(await rigged.store.queue_items()) == 1
    item = await rigged.store.queue_item("le_1")
    assert item is not None and item.candidate_requested is False

    rigged.pipeline.unavailable = False
    await rigged.service.record_report(_report(client_id="cr_2"), "reader-2")

    assert len(rigged.pipeline.candidates) == 1


@pytest.mark.asyncio
async def test_a_report_on_a_word_lookup_without_a_clip_is_refused() -> None:
    rigged = rig(word_lookup(entries=(), status=LookupStatus.FALLBACK))

    with pytest.raises(NoClipServedError):
        await rigged.service.record_report(_report(), SUBJECT)

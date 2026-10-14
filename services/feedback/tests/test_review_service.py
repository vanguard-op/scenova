"""Service tests for the curator review surface (FEAT-015).

These drive the review service directly, so the queue filters, the entry detail,
and each action's effect on the library and the queue item are observable without
the wire contract.
"""

from __future__ import annotations

import pytest

from feedback.app.errors import (
    InvalidRequestError,
    ReviewConflictError,
    ReviewEntryNotFoundError,
    ReviewUnavailableError,
)
from feedback.app.models import (
    ActionRequest,
    ModerationActionName,
    Rating,
    ReportReason,
    ReportStatus,
    ReviewState,
)
from feedback.app.store import (
    FeedbackRecord,
    ReportRecord,
    ReviewItem,
    new_queue_item,
    queue_feedback,
    queue_report,
)
from feedback.tests.fakes import FullRig, entry_view, full_rig

_NOW = "2026-10-14T00:00:00+00:00"
_LATER = "2026-10-14T01:00:00+00:00"


async def _queue_report(
    rig: FullRig,
    entry_id: str = "le_1",
    *,
    report_id: str = "rp_1",
    reason: ReportReason = ReportReason.WRONG_MEANING,
    created_at: str = _NOW,
) -> ReviewItem:
    item = new_queue_item(entry_id, now=created_at)
    item = queue_report(item, report_id=report_id, reason=reason, now=created_at)
    await rig.store.save_queue_item(item)
    await rig.store.add_report(
        ReportRecord(
            id=report_id,
            lookup_id="lk_1",
            subject="reader-1",
            client_report_id=f"cr_{report_id}",
            reason=reason,
            note="the clip shows another sense",
            entry_ids=(entry_id,),
            status=ReportStatus.QUEUED,
            created_at=created_at,
        )
    )
    return item


async def _add_feedback(
    rig: FullRig,
    entry_id: str = "le_1",
    *,
    rating: Rating = Rating.WRONG,
    created_at: str = _NOW,
) -> None:
    await rig.store.add_feedback(
        FeedbackRecord(
            id=f"fb_{entry_id}_{created_at}",
            lookup_id="lk_1",
            subject="reader-1",
            client_feedback_id=f"cf_{entry_id}_{created_at}",
            rating=rating,
            entry_ids=(entry_id,),
            created_at=created_at,
        )
    )


def _action(
    action: ModerationActionName,
    *,
    phrase: str | None = None,
    notes: str | None = None,
    expected_state: ReviewState = ReviewState.QUEUED,
) -> ActionRequest:
    return ActionRequest(action=action, phrase=phrase, notes=notes, expectedState=expected_state)


@pytest.mark.asyncio
async def test_the_queue_lists_a_queued_entry_with_its_reason_and_state() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    response = await rigged.review.queue(reason=None, state=None, word=None, page=1)

    assert response.openCount == 1
    assert response.page == 1
    assert response.pageCount == 1
    item = response.items[0]
    assert item.entryId == "le_1"
    assert item.lemma == "come"
    assert item.senseLabel == "arrive"
    assert item.reason == "wrong_meaning"
    assert item.queuedAt == _NOW
    assert item.state is ReviewState.QUEUED


@pytest.mark.asyncio
async def test_a_feedback_only_entry_is_queued_with_the_feedback_reason() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    item = queue_feedback(new_queue_item("le_1", now=_NOW), now=_NOW)
    await rigged.store.save_queue_item(item)

    response = await rigged.review.queue(reason=None, state=None, word=None, page=1)

    assert response.items[0].reason == "feedback_threshold"


@pytest.mark.asyncio
async def test_the_queue_filters_by_reason_state_and_word() -> None:
    rigged = full_rig(
        entries={
            "le_1": entry_view("le_1", lemma="come"),
            "le_2": entry_view("le_2", lemma="bank", sense_label="river edge"),
        }
    )
    await _queue_report(rigged, "le_1", reason=ReportReason.WRONG_MEANING)
    await _queue_report(
        rigged, "le_2", report_id="rp_2", reason=ReportReason.OFFENSIVE, created_at=_LATER
    )

    by_reason = await rigged.review.queue(reason="offensive", state=None, word=None, page=1)
    by_word = await rigged.review.queue(reason=None, state=None, word="BANK", page=1)
    no_match = await rigged.review.queue(reason="low_quality", state=None, word=None, page=1)

    assert [item.entryId for item in by_reason.items] == ["le_2"]
    assert [item.entryId for item in by_word.items] == ["le_2"]
    assert no_match.items == []
    # The open count is over the whole queue, not the filtered window.
    assert no_match.openCount == 2


@pytest.mark.asyncio
async def test_the_queue_lists_the_newest_report_first() -> None:
    rigged = full_rig(
        entries={
            "le_1": entry_view("le_1", lemma="come"),
            "le_2": entry_view("le_2", lemma="bank"),
        }
    )
    await _queue_report(rigged, "le_1", created_at=_NOW)
    await _queue_report(rigged, "le_2", report_id="rp_2", created_at=_LATER)

    response = await rigged.review.queue(reason=None, state=None, word=None, page=1)

    assert [item.entryId for item in response.items] == ["le_2", "le_1"]


@pytest.mark.asyncio
async def test_the_queue_pages_a_long_queue() -> None:
    entries = {f"le_{i}": entry_view(f"le_{i}", lemma=f"word{i}") for i in range(25)}
    rigged = full_rig(entries=entries)
    for i in range(25):
        await _queue_report(
            rigged,
            f"le_{i}",
            report_id=f"rp_{i}",
            created_at=f"2026-10-14T00:{i:02d}:00+00:00",
        )

    first = await rigged.review.queue(reason=None, state=None, word=None, page=1)
    second = await rigged.review.queue(reason=None, state=None, word=None, page=2)

    assert first.pageCount == 2
    assert len(first.items) == 20
    assert len(second.items) == 5
    assert second.page == 2


@pytest.mark.asyncio
async def test_a_queue_item_whose_entry_is_gone_is_left_out() -> None:
    rigged = full_rig(entries={})
    await _queue_report(rigged)

    response = await rigged.review.queue(reason=None, state=None, word=None, page=1)

    assert response.items == []
    assert response.openCount == 0


@pytest.mark.asyncio
async def test_the_entry_shows_its_clip_evidence_and_state() -> None:
    rigged = full_rig(entries={"le_1": entry_view(gloss_phrase="to move toward a place")})
    await _queue_report(rigged)
    await _add_feedback(rigged, rating=Rating.WRONG)
    await _add_feedback(rigged, rating=Rating.HELPFUL, created_at=_LATER)

    response = await rigged.review.entry("le_1")

    assert response.entry.entryId == "le_1"
    assert response.entry.glossPhrase == "to move toward a place"
    assert response.entry.status.value == "active"
    assert response.entry.clip.url == "https://cdn.example/clip_1.mp4"
    assert [report.reason for report in response.reports] == ["wrong_meaning"]
    assert response.reports[0].note == "the clip shows another sense"
    # Only the negative rating is evidence; a helpful one is not shown.
    assert [feedback.rating for feedback in response.feedback] == [Rating.WRONG]
    assert response.state is ReviewState.QUEUED


@pytest.mark.asyncio
async def test_an_entry_with_nothing_queued_is_not_found() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with pytest.raises(ReviewEntryNotFoundError):
        await rigged.review.entry("le_1")


@pytest.mark.asyncio
async def test_clear_returns_the_entry_to_serving_and_resolves_the_item() -> None:
    rigged = full_rig(entries={"le_1": entry_view(status="held")})
    await _queue_report(rigged)

    response = await rigged.review.act("le_1", _action(ModerationActionName.CLEAR))

    assert response.status.value == "active"
    assert response.state is ReviewState.ACTIONED
    assert rigged.library.statuses == [("le_1", "active")]
    item = await rigged.store.queue_item("le_1")
    assert item is not None and item.state is ReviewState.ACTIONED
    reports = await rigged.store.reports_for_entry("le_1")
    assert reports[0].status is ReportStatus.ACTIONED
    actions = await rigged.store.moderation_actions()
    assert actions[0].action is ModerationActionName.CLEAR
    assert actions[0].actor_role == "curator"
    assert actions[0].report_id == "rp_1"


@pytest.mark.asyncio
async def test_hold_withholds_the_entry() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    response = await rigged.review.act("le_1", _action(ModerationActionName.HOLD))

    assert response.status.value == "held"
    assert response.state is ReviewState.ACTIONED
    assert rigged.library.statuses == [("le_1", "held")]
    assert rigged.regeneration.calls == []


@pytest.mark.asyncio
async def test_retire_stops_serving_without_regenerating_now() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    response = await rigged.review.act("le_1", _action(ModerationActionName.RETIRE))

    assert response.status.value == "retired"
    assert response.state is ReviewState.ACTIONED
    assert rigged.library.statuses == [("le_1", "retired")]
    # Retiring leaves the replacement to the next lookup; no job is enqueued now.
    assert rigged.regeneration.calls == []


@pytest.mark.asyncio
async def test_replace_retires_and_regenerates_with_a_fresh_phrase() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    response = await rigged.review.act("le_1", _action(ModerationActionName.REPLACE))

    assert response.status.value == "retired"
    assert response.state is ReviewState.ACTIONED
    assert rigged.library.statuses == [("le_1", "retired")]
    assert rigged.regeneration.calls == [("le_1", None)]


@pytest.mark.asyncio
async def test_edit_phrase_records_the_phrase_and_regenerates_from_it() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    response = await rigged.review.act(
        "le_1",
        _action(ModerationActionName.EDIT_PHRASE, phrase="to arrive somewhere"),
    )

    assert response.status.value == "retired"
    # A phrase edit regenerates and leaves the entry under review.
    assert response.state is ReviewState.REVIEWED
    assert rigged.regeneration.calls == [("le_1", "to arrive somewhere")]
    actions = await rigged.store.moderation_actions()
    assert actions[0].phrase == "to arrive somewhere"


@pytest.mark.asyncio
async def test_edit_phrase_without_a_phrase_is_refused() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)

    with pytest.raises(InvalidRequestError):
        await rigged.review.act("le_1", _action(ModerationActionName.EDIT_PHRASE, phrase="   "))


@pytest.mark.asyncio
async def test_a_second_action_after_the_entry_moved_conflicts() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})
    await _queue_report(rigged)
    await rigged.review.act("le_1", _action(ModerationActionName.CLEAR))

    with pytest.raises(ReviewConflictError):
        await rigged.review.act("le_1", _action(ModerationActionName.HOLD))


@pytest.mark.asyncio
async def test_acting_on_an_entry_with_nothing_queued_is_not_found() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with pytest.raises(ReviewEntryNotFoundError):
        await rigged.review.act("le_1", _action(ModerationActionName.CLEAR))


@pytest.mark.asyncio
async def test_acting_when_the_library_lost_the_entry_is_not_found() -> None:
    rigged = full_rig(entries={})
    await _queue_report(rigged)

    with pytest.raises(ReviewEntryNotFoundError):
        await rigged.review.act("le_1", _action(ModerationActionName.CLEAR))


@pytest.mark.asyncio
async def test_an_unreachable_library_is_unavailable() -> None:
    rigged = full_rig(entries={"le_1": entry_view()}, library_unavailable=True)
    await _queue_report(rigged)

    with pytest.raises(ReviewUnavailableError):
        await rigged.review.act("le_1", _action(ModerationActionName.CLEAR))


@pytest.mark.asyncio
async def test_an_unreachable_pipeline_makes_a_replace_unavailable() -> None:
    rigged = full_rig(entries={"le_1": entry_view()}, regeneration_unavailable=True)
    await _queue_report(rigged)

    with pytest.raises(ReviewUnavailableError):
        await rigged.review.act("le_1", _action(ModerationActionName.REPLACE))

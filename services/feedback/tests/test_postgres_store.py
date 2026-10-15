"""Relational store tests for feedback, reports, and the review queue (FEAT-010,
FEAT-011, FEAT-015).

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: a rating and a report survive
the request that made them and are reached back through the lookup that served
the entry, the review queue holds one item per entry with its evidence, a curator
action records the clip it chose, and a deleted reader's identity is stripped
while the rating and reason survive as usage evidence (schema.md "Feedback",
"Report", "ReviewItem", "ModerationAction"; C-012 to C-016; nfr.md "Privacy &
Compliance").

The real tables are the platform's migration history (`infra/db/migrations`);
the tests build the same shape from the store's model metadata, plus the read-only
`lookups` and `library_entries` references the store joins, so the queries and the
row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import pytest
from sqlalchemy import UniqueConstraint, create_engine
from sqlalchemy.engine import Engine

from feedback.app.config import Settings
from feedback.app.db import LIBRARY_ENTRIES, LOOKUPS, Base
from feedback.app.errors import FeedbackStoreUnavailableError
from feedback.app.models import (
    FeedbackRequest,
    ModerationActionName,
    Rating,
    ReportReason,
    ReportStatus,
    ReviewState,
)
from feedback.app.service import FeedbackService, build_default_store
from feedback.app.store import (
    FeedbackRecord,
    ModerationActionRecord,
    PostgresFeedbackStore,
    ReportRecord,
    ReviewItem,
    new_queue_item,
    queue_feedback,
    queue_report,
)
from feedback.tests.fakes import (
    FakeLibrary,
    FakeLookupDirectory,
    FakePipeline,
    word_lookup,
)

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"

_T1 = "2026-10-14T00:00:00+00:00"
_T2 = "2026-10-14T01:00:00+00:00"


def _engine(tmp_path: Path, name: str = "feedback.db") -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    # The lookup and library-entry tables another service owns are read-only
    # references here; the tests create the same shape the migration defines.
    LOOKUPS.create(engine, checkfirst=True)
    LIBRARY_ENTRIES.create(engine, checkfirst=True)
    return engine


def _seed_lookup(engine: Engine, lookup_id: str, served_entry_id: str | None) -> None:
    with engine.begin() as connection:
        connection.execute(LOOKUPS.insert().values(id=lookup_id, served_entry_id=served_entry_id))


def _seed_entry(
    engine: Engine,
    entry_id: str,
    *,
    clip_asset_id: str = "clip_1",
    candidate_clip_asset_id: str | None = None,
) -> None:
    with engine.begin() as connection:
        connection.execute(
            LIBRARY_ENTRIES.insert().values(
                id=entry_id,
                clip_asset_id=clip_asset_id,
                candidate_clip_asset_id=candidate_clip_asset_id,
            )
        )


@asynccontextmanager
async def _store(engine: Engine) -> AsyncIterator[PostgresFeedbackStore]:
    store = PostgresFeedbackStore(engine)
    try:
        yield store
    finally:
        await store.aclose()


def _feedback(
    record_id: str = "fb_1",
    *,
    lookup_id: str = "lk_1",
    subject: str = "reader-1",
    client_id: str = "cf_1",
    rating: Rating = Rating.HELPFUL,
    created_at: str = _T1,
) -> FeedbackRecord:
    return FeedbackRecord(
        id=record_id,
        lookup_id=lookup_id,
        subject=subject,
        client_feedback_id=client_id,
        rating=rating,
        entry_ids=("le_1",),
        created_at=created_at,
    )


def _report(
    record_id: str = "rp_1",
    *,
    lookup_id: str = "lk_1",
    subject: str = "reader-1",
    client_id: str = "cr_1",
    reason: ReportReason = ReportReason.WRONG_MEANING,
    note: str | None = "the clip shows another sense",
    status: ReportStatus = ReportStatus.QUEUED,
    created_at: str = _T1,
) -> ReportRecord:
    return ReportRecord(
        id=record_id,
        lookup_id=lookup_id,
        subject=subject,
        client_report_id=client_id,
        reason=reason,
        note=note,
        entry_ids=("le_1",),
        status=status,
        created_at=created_at,
    )


def test_the_schema_keys_feedback_and_reports_per_reader_and_client_key() -> None:
    # schema.md "Feedback", "Report", "ReviewItem": a reader's rating is unique on
    # their client key, and an entry holds one queue item however many reports it
    # has (C-012, C-013, C-014).
    def unique_keys(table_name: str) -> set[tuple[str, ...]]:
        return {
            tuple(sorted(column.name for column in constraint.columns))
            for constraint in Base.metadata.tables[table_name].constraints
            if isinstance(constraint, UniqueConstraint)
        }

    assert ("client_feedback_id", "subject") in unique_keys("feedback")
    assert ("client_report_id", "subject") in unique_keys("reports")
    assert ("entry_id",) in unique_keys("review_items")


@pytest.mark.asyncio
async def test_a_rating_is_read_back_against_the_entry_the_lookup_served(
    tmp_path: Path,
) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_feedback(_feedback())

        stored = await store.feedback_for_client("reader-1", "cf_1")

    assert stored is not None
    assert stored.rating is Rating.HELPFUL
    assert stored.lookup_id == "lk_1"
    assert stored.entry_ids == ("le_1",)


@pytest.mark.asyncio
async def test_a_phrase_rating_carries_no_shared_entry(tmp_path: Path) -> None:
    # A phrase clip is private to the device, so its lookup served no entry and
    # the rating touches no shared library entry (FEAT-010).
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", None)
    async with _store(engine) as store:
        await store.add_feedback(_feedback())

        stored = await store.feedback_for_client("reader-1", "cf_1")

    assert stored is not None and stored.entry_ids == ()


@pytest.mark.asyncio
async def test_an_idempotency_key_finds_the_rating_it_made(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_feedback(_feedback())

        found = await store.feedback_for_client("reader-1", "cf_1")
        other_reader = await store.feedback_for_client("reader-2", "cf_1")

    assert found is not None and found.id == "fb_1"
    assert other_reader is None


@pytest.mark.asyncio
async def test_only_a_readers_latest_rating_of_an_entry_counts(tmp_path: Path) -> None:
    # FEAT-010 edge: repeated feedback from one reader counts only its latest, so
    # a reader who changes to helpful no longer counts against the entry.
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    _seed_lookup(engine, "lk_2", "le_1")
    async with _store(engine) as store:
        await store.add_feedback(
            _feedback(
                "fb_1", lookup_id="lk_1", subject="reader-1", client_id="cf_1", rating=Rating.WRONG
            )
        )
        await store.add_feedback(
            _feedback(
                "fb_2",
                lookup_id="lk_2",
                subject="reader-1",
                client_id="cf_2",
                rating=Rating.HELPFUL,
                created_at=_T2,
            )
        )
        await store.add_feedback(
            _feedback(
                "fb_3",
                lookup_id="lk_1",
                subject="reader-2",
                client_id="cf_3",
                rating=Rating.NOT_HELPFUL,
            )
        )

        negative = await store.negative_raters("le_1")
        flagged = await store.is_flagged("le_1")

    assert negative == 1, "reader-1's latest is helpful; only reader-2 counts"
    assert flagged is True


@pytest.mark.asyncio
async def test_a_report_is_reached_back_through_the_lookup_that_served_it(
    tmp_path: Path,
) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_report(_report())

        reports = await store.reports_for_entry("le_1")
        elsewhere = await store.reports_for_entry("le_2")
        stored = await store.report_for_client("reader-1", "cr_1")

    assert [record.id for record in reports] == ["rp_1"]
    assert reports[0].reason is ReportReason.WRONG_MEANING
    assert reports[0].entry_ids == ("le_1",)
    assert elsewhere == []
    assert stored is not None and stored.note == "the clip shows another sense"


@pytest.mark.asyncio
async def test_a_reader_has_reported_the_entry_their_lookup_served(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_report(_report())

        assert await store.has_reported("reader-1", "le_1") is True
        assert await store.has_reported("reader-2", "le_1") is False


@pytest.mark.asyncio
async def test_a_queue_item_reads_its_reasons_and_reports_from_the_evidence(
    tmp_path: Path,
) -> None:
    # The queue item's reasons and report ids are not stored on the row; they are
    # read from the reports against its entry, so one item holds every report it
    # has (C-014).
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_report(_report(reason=ReportReason.WRONG_MEANING))
        await store.add_report(
            _report(
                "rp_2",
                subject="reader-2",
                client_id="cr_2",
                reason=ReportReason.OFFENSIVE,
                created_at=_T2,
            )
        )
        item = new_queue_item("le_1", now=_T1)
        item = queue_report(item, report_id="rp_1", reason=ReportReason.WRONG_MEANING, now=_T1)
        item = queue_report(item, report_id="rp_2", reason=ReportReason.OFFENSIVE, now=_T2)
        await store.save_queue_item(item)

        stored = await store.queue_item("le_1")

    assert stored is not None
    assert set(stored.reasons) == {"wrong_meaning", "offensive"}
    assert set(stored.report_ids) == {"rp_1", "rp_2"}
    assert stored.state is ReviewState.QUEUED
    assert stored.created_at == _T1


@pytest.mark.asyncio
async def test_a_feedback_only_item_carries_the_threshold_reason(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.save_queue_item(queue_feedback(new_queue_item("le_1", now=_T1), now=_T1))

        stored = await store.queue_item("le_1")

    assert stored is not None
    assert stored.reasons == ("feedback_threshold",)
    assert stored.report_ids == ()


@pytest.mark.asyncio
async def test_a_resolved_item_records_its_state(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    async with _store(engine) as store:
        await store.add_report(_report())
        await store.save_queue_item(new_queue_item("le_1", now=_T1))

        await store.set_reports_status("le_1", ReportStatus.ACTIONED)
        await store.save_queue_item(
            ReviewItem(
                entry_id="le_1",
                reasons=(),
                report_ids=(),
                created_at=_T1,
                updated_at=_T2,
                state=ReviewState.ACTIONED,
            )
        )

        stored = await store.queue_item("le_1")
        reports = await store.reports_for_entry("le_1")

    assert stored is not None and stored.state is ReviewState.ACTIONED
    assert reports[0].status is ReportStatus.ACTIONED


@pytest.mark.asyncio
async def test_a_curator_action_records_the_clip_it_chose(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    _seed_entry(engine, "le_1", clip_asset_id="clip_1", candidate_clip_asset_id="clip_cand")
    async with _store(engine) as store:
        await store.add_moderation_action(
            ModerationActionRecord(
                id="ma_1",
                entry_id="le_1",
                report_id="rp_1",
                action=ModerationActionName.CHOOSE,
                actor_role="curator",
                chosen_clip="candidate",
                phrase=None,
                notes="the fresh clip is closer",
                created_at=_T1,
            )
        )
        await store.add_moderation_action(
            ModerationActionRecord(
                id="ma_2",
                entry_id="le_1",
                report_id=None,
                action=ModerationActionName.EDIT_PHRASE,
                actor_role="curator",
                chosen_clip=None,
                phrase="to arrive somewhere",
                notes=None,
                created_at=_T2,
            )
        )

        actions = await store.moderation_actions()

    assert [action.id for action in actions] == ["ma_1", "ma_2"]
    assert actions[0].action is ModerationActionName.CHOOSE
    assert actions[0].chosen_clip == "candidate"
    assert actions[0].notes == "the fresh clip is closer"
    assert actions[1].phrase == "to arrive somewhere"


@pytest.mark.asyncio
async def test_anonymizing_a_reader_strips_their_identity_and_keeps_the_evidence(
    tmp_path: Path,
) -> None:
    engine = _engine(tmp_path)
    _seed_lookup(engine, "lk_1", "le_1")
    _seed_lookup(engine, "lk_2", "le_1")
    async with _store(engine) as store:
        await store.add_feedback(_feedback("fb_1", subject="reader-1", client_id="cf_1"))
        await store.add_feedback(
            _feedback("fb_2", lookup_id="lk_2", subject="reader-2", client_id="cf_2")
        )
        await store.add_report(_report("rp_1", subject="reader-1", client_id="cr_1"))

        anonymized = await store.anonymize_subject("reader-1")

        key = await store.feedback_for_client("reader-1", "cf_1")
        report_key = await store.report_for_client("reader-1", "cr_1")
        untouched = await store.feedback_for_client("reader-2", "cf_2")
        evidence = await store.feedback_for_entry("le_1")
        reports = await store.reports_for_entry("le_1")
        again = await store.anonymize_subject("reader-1")

    assert anonymized == 2
    assert key is None, "the idempotency key goes with the reader who held it"
    assert report_key is None
    assert untouched is not None and untouched.subject == "reader-2"
    assert len(evidence) == 2, "the rating survives as usage evidence"
    assert reports[0].reason is ReportReason.WRONG_MEANING
    assert again == 0, "a re-run for an already anonymized reader finds nothing"


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_unavailable() -> None:
    store = PostgresFeedbackStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(FeedbackStoreUnavailableError):
            await store.feedback_for_client("reader-1", "cf_1")
    finally:
        await store.aclose()


@pytest.mark.asyncio
async def test_an_unreachable_store_is_unavailable_through_the_intake() -> None:
    # The intake answers 503 when its store cannot be reached, so the client
    # retries rather than the rating being silently dropped (C-012).
    service = FeedbackService(
        store=PostgresFeedbackStore(create_engine(_UNREACHABLE)),
        lookups=FakeLookupDirectory(word_lookup()),
        library=FakeLibrary(),
        pipeline=FakePipeline(),
        negative_feedback_threshold=3,
    )
    try:
        with pytest.raises(FeedbackStoreUnavailableError):
            await service.record_feedback(
                FeedbackRequest(lookupId="lk_1", rating=Rating.HELPFUL, clientFeedbackId="cf_1"),
                "reader-1",
            )
    finally:
        await service.aclose()


@pytest.mark.asyncio
async def test_the_default_store_is_relational_when_a_database_is_configured(
    tmp_path: Path,
) -> None:
    url = f"sqlite:///{tmp_path / 'service.db'}"
    engine = create_engine(url)
    Base.metadata.create_all(engine)
    LOOKUPS.create(engine, checkfirst=True)
    _seed_lookup(engine, "lk_1", "le_1")

    store = build_default_store(Settings(database_url=url))
    try:
        assert isinstance(store, PostgresFeedbackStore)
        await store.add_feedback(_feedback())
        found = await store.feedback_for_client("reader-1", "cf_1")
    finally:
        await store.aclose()

    assert found is not None and found.entry_ids == ("le_1",)


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None

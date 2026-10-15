"""Relational store tests for accounts, entitlements, and purchases (FEAT-013).

The relational store is what the primary database holds, so these tests run the
same store over an in-process relational engine: an account and its entitlement
survive the request that made them, a store billing event is applied once however
many times the processor redelivers it, a resent lookup is metered once, a
deleted account is marked and loses its entitlement at once, and the retention
pass hard-deletes the record while the financial record stays on file (schema.md
"Account", "Entitlement", "Purchase"; C-018 to C-022; nfr.md "Privacy &
Compliance").

The real tables are the platform's migration history (`infra/db/migrations`); the
tests build the same shape from the store's model metadata, so the queries and
the row mapping are exercised without a database server.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

from entitlement.app.auth import Subject
from entitlement.app.config import Settings
from entitlement.app.db import Base
from entitlement.app.errors import EntitlementUnavailableError
from entitlement.app.models import (
    BillingEvent,
    EntitlementStatus,
    EntitlementSyncRequest,
    Plan,
    ProductKind,
    PurchaseStatus,
    StoreName,
)
from entitlement.app.service import EntitlementService
from entitlement.app.store import (
    AccountRecord,
    EntitlementRecord,
    PostgresEntitlementStore,
    PurchaseRecord,
    build_default_store,
)
from entitlement.tests.fakes import START, Clock

# A path SQLite cannot create, standing in for the database being unreachable.
_UNREACHABLE = "sqlite:////nonexistent-directory-xyz/scenova.db"

_T1 = "2026-10-15T12:00:00+00:00"
_T2 = "2026-10-15T13:00:00+00:00"
_PERIOD_END = "2026-11-15T12:00:00+00:00"
_TRIAL_END = "2026-10-22T12:00:00+00:00"


def _engine(tmp_path: Path, name: str = "entitlement.db") -> Engine:
    engine = create_engine(f"sqlite:///{tmp_path / name}")
    Base.metadata.create_all(engine)
    return engine


@asynccontextmanager
async def _store(engine: Engine) -> AsyncIterator[PostgresEntitlementStore]:
    store = PostgresEntitlementStore(engine)
    try:
        yield store
    finally:
        await store.aclose()


def _account(
    account_id: str = "reader-1",
    *,
    locale: str = "en",
    consent: bool = False,
    deleted_at: str | None = None,
) -> AccountRecord:
    return AccountRecord(
        id=account_id,
        email=f"{account_id}@example.com",
        locale=locale,
        consent_model_processing=consent,
        consent_updated_at=_T1,
        created_at=_T1,
        deleted_at=deleted_at,
    )


def _entitlement(
    account_id: str = "reader-1",
    *,
    plan: Plan = Plan.TRIAL,
    lookups_used: int = 0,
    lookups_limit: int = 50,
    renewing: bool = True,
    status: EntitlementStatus = EntitlementStatus.ACTIVE,
) -> EntitlementRecord:
    return EntitlementRecord(
        id=f"en_{account_id}",
        account_id=account_id,
        plan=plan,
        lookups_used=lookups_used,
        lookups_limit=lookups_limit,
        period_start=_T1,
        period_end=_PERIOD_END,
        status=status,
        trial_ends_at=_TRIAL_END if plan is Plan.TRIAL else None,
        updated_at=_T1,
        renewing=renewing,
    )


def _purchase(
    purchase_id: str = "pu_1",
    *,
    account_id: str = "reader-1",
    product_id: str = "scenova.pro.monthly",
    product_kind: ProductKind = ProductKind.SUBSCRIPTION,
    status: PurchaseStatus = PurchaseStatus.ACTIVE,
    purchased_at: str = _T1,
    refunded_at: str | None = None,
) -> PurchaseRecord:
    return PurchaseRecord(
        id=purchase_id,
        account_id=account_id,
        store=StoreName.APP_STORE,
        product_id=product_id,
        product_kind=product_kind,
        status=status,
        amount_minor=699,
        currency="USD",
        purchased_at=purchased_at,
        refunded_at=refunded_at,
    )


def _service(store: PostgresEntitlementStore) -> EntitlementService:
    return EntitlementService(
        store=store,
        free_lookups=20,
        pro_lookups=50,
        topup_lookups=20,
        trial_days=7,
        retention_days=30,
        clock=Clock(START),
    )


@pytest.mark.asyncio
async def test_an_account_and_its_choices_are_read_back(tmp_path: Path) -> None:
    # C-020, C-022: the consent choice and the locale live on the account, so a
    # sign-in on a new device finds the same account.
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.save_account(_account(locale="fr", consent=True))

        stored = await store.account("reader-1")
        elsewhere = await store.account("reader-2")

    assert stored is not None
    assert stored.locale == "fr"
    assert stored.consent_model_processing is True
    assert stored.deleted_at is None
    assert elsewhere is None


@pytest.mark.asyncio
async def test_an_existing_account_is_left_as_it_is(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account(consent=True))
        again = await store.create_account(_account(consent=False))

    assert again.consent_model_processing is True


@pytest.mark.asyncio
async def test_an_entitlement_round_trips_its_plan_and_period(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.save_entitlement(_entitlement(lookups_used=3))

        stored = await store.entitlement("reader-1")

    assert stored is not None
    assert stored.plan is Plan.TRIAL
    assert stored.lookups_used == 3
    assert stored.lookups_limit == 50
    assert stored.period_end == _PERIOD_END
    assert stored.trial_ends_at == _TRIAL_END
    assert stored.renewing is True


@pytest.mark.asyncio
async def test_saving_an_entitlement_replaces_the_one_under_the_account(tmp_path: Path) -> None:
    # Each account holds one entitlement for the current period, so a roll or a
    # billing event replaces it rather than adding a second row.
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.save_entitlement(_entitlement())
        await store.save_entitlement(
            _entitlement(
                plan=Plan.PRO,
                lookups_used=1,
                status=EntitlementStatus.GRACE,
                renewing=False,
            )
        )

        stored = await store.entitlement("reader-1")
        rows = _scalar_count(engine, "entitlements")

    assert stored is not None
    assert stored.plan is Plan.PRO
    assert stored.status is EntitlementStatus.GRACE
    assert stored.renewing is False
    assert stored.trial_ends_at is None
    assert rows == 1


@pytest.mark.asyncio
async def test_a_deleted_account_loses_its_entitlement_at_once(tmp_path: Path) -> None:
    # C-021: from the deletion on, the token's subject has no account and no
    # further lookup can meter against it.
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.save_entitlement(_entitlement())
        await store.delete_account(_account(deleted_at=_T2))

        account = await store.account("reader-1")
        entitlement = await store.entitlement("reader-1")

    assert account is not None and account.deleted_at == _T2
    assert entitlement is None


@pytest.mark.asyncio
async def test_a_purchase_is_read_back_by_its_store_product(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.record_purchase(_purchase())
        await store.record_purchase(_purchase("pu_2", purchased_at=_T2))
        await store.record_purchase(_purchase("pu_3", account_id="reader-2"))

        mine = await store.purchases_for(
            "reader-1", StoreName.APP_STORE, "scenova.pro.monthly", ProductKind.SUBSCRIPTION
        )
        other_kind = await store.purchases_for(
            "reader-1", StoreName.APP_STORE, "scenova.pro.monthly", ProductKind.TOPUP
        )

    assert [purchase.id for purchase in mine] == ["pu_1", "pu_2"]
    assert other_kind == []


@pytest.mark.asyncio
async def test_a_refund_replaces_the_purchases_state(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account())
        await store.record_purchase(_purchase())
        await store.save_purchase(
            replace(
                _purchase(),
                status=PurchaseStatus.REFUNDED,
                refunded_at=_T2,
            )
        )

        stored = await store.purchases_for(
            "reader-1", StoreName.APP_STORE, "scenova.pro.monthly", ProductKind.SUBSCRIPTION
        )

    assert len(stored) == 1
    assert stored[0].status is PurchaseStatus.REFUNDED
    assert stored[0].refunded_at == _T2


@pytest.mark.asyncio
async def test_the_retention_pass_goes_only_past_the_window(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account("reader-1", deleted_at=_T1))
        await store.create_account(_account("reader-2", deleted_at=_T2))
        await store.save_entitlement(_entitlement("reader-1"))
        await store.save_entitlement(_entitlement("reader-2"))

        # A cutoff between the two deletions: the earlier one goes.
        purged = await store.purge_deleted_before(datetime(2026, 10, 15, 12, 30, tzinfo=UTC))

        gone = await store.account("reader-1")
        kept = await store.account("reader-2")
        kept_entitlement = await store.entitlement("reader-2")

    assert purged == 1
    assert gone is None
    assert kept is not None and kept.deleted_at == _T2
    assert kept_entitlement is not None


@pytest.mark.asyncio
async def test_the_retention_pass_keeps_the_financial_record(tmp_path: Path) -> None:
    # nfr.md "Data lifecycle": a purchase is kept for seven years, so the
    # account's personal data goes while the purchase stays on file.
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account(deleted_at=_T1))
        await store.save_entitlement(_entitlement())
        await store.record_purchase(_purchase())

        await store.purge_deleted_before(datetime(2026, 11, 15, tzinfo=UTC))

        gone = await store.account("reader-1")
        entitlement = await store.entitlement("reader-1")

    assert gone is None
    assert entitlement is None
    # The purchase survives its account: the account reference detaches rather
    # than the row being removed with it.
    with engine.connect() as connection:
        rows = connection.execute(text("select id, account_id from purchases")).all()
    assert [row.id for row in rows] == ["pu_1"]
    assert rows[0].account_id is None


@pytest.mark.asyncio
async def test_the_retention_pass_is_idempotent(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        await store.create_account(_account(deleted_at=_T1))
        first = await store.purge_deleted_before(datetime(2026, 11, 15, tzinfo=UTC))
        second = await store.purge_deleted_before(datetime(2026, 11, 15, tzinfo=UTC))

    assert first == 1
    assert second == 0


@pytest.mark.asyncio
async def test_a_billing_event_and_a_lookup_are_each_recorded_once(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    async with _store(engine) as store:
        assert await store.event_applied("reader-1|purchase") is False
        await store.mark_event_applied("reader-1|purchase")
        assert await store.event_applied("reader-1|purchase") is True

        assert await store.lookup_applied("reader-1", "lk_1") is False
        await store.mark_lookup_applied("reader-1", "lk_1")
        assert await store.lookup_applied("reader-1", "lk_1") is True
        # The key is the reader's own: another reader's lookup of the same key is
        # its own spend.
        assert await store.lookup_applied("reader-2", "lk_1") is False


@pytest.mark.asyncio
async def test_the_service_applies_a_redelivered_event_once(tmp_path: Path) -> None:
    # The ledger is what stops a redelivered top-up adding its lookups twice, so
    # it is exercised through the service that reads it (C-019).
    engine = _engine(tmp_path)
    service = _service(PostgresEntitlementStore(engine))
    try:
        reader = Subject(id="reader-1")
        await service.entitlement(reader)
        body = EntitlementSyncRequest(
            accountId="reader-1",
            event=BillingEvent.PURCHASE,
            store=StoreName.APP_STORE,
            productId="scenova.topup.20",
            productKind=ProductKind.TOPUP,
            amountMinor=299,
            currency="USD",
            occurredAt=_T1,
        )
        first = await service.sync(body)
        second = await service.sync(body)
        after = await service.entitlement(reader)
    finally:
        await service.aclose()

    assert first.applied is True
    assert second.applied is False
    assert after.lookupsLimit == 70


@pytest.mark.asyncio
async def test_the_service_meters_a_resent_lookup_once(tmp_path: Path) -> None:
    engine = _engine(tmp_path)
    service = _service(PostgresEntitlementStore(engine))
    try:
        reader = Subject(id="reader-1")
        await service.entitlement(reader)
        await service.spend(reader, "lk_1")
        await service.spend(reader, "lk_1")
        after = await service.entitlement(reader)
    finally:
        await service.aclose()

    assert after.lookupsUsed == 1


@pytest.mark.asyncio
async def test_an_unreachable_database_is_reported_as_unavailable() -> None:
    store = PostgresEntitlementStore(create_engine(_UNREACHABLE))
    try:
        with pytest.raises(EntitlementUnavailableError):
            await store.account("reader-1")
    finally:
        await store.aclose()


def test_the_default_store_is_relational_when_a_database_is_configured(tmp_path: Path) -> None:
    url = f"sqlite:///{tmp_path / 'service.db'}"
    Base.metadata.create_all(create_engine(url))

    store = build_default_store(Settings(database_url=url))

    assert isinstance(store, PostgresEntitlementStore)


def test_the_database_url_is_read_from_the_environment() -> None:
    assert Settings.from_env({"DATABASE_URL": "postgresql+psycopg://db"}).database_url == (
        "postgresql+psycopg://db"
    )
    assert Settings.from_env({}).database_url is None


def _scalar_count(engine: Engine, table: str) -> int:
    with engine.connect() as connection:
        return int(connection.execute(text(f"select count(*) from {table}")).scalar_one())

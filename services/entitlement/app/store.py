"""Account, entitlement, and purchase persistence (FEAT-013).

The store holds the `schema.md` entities "Account", "Entitlement", and
"Purchase". An account is keyed by the reader's identity subject, which is the
same across the reader's devices, so a sign-in on a new device finds the same
account and the entitlement follows it. Each account has one entitlement for the
current allowance period.

Two idempotency ledgers sit beside them. A store billing event is recorded once
however many times the processor redelivers its webhook, and a lookup is metered
once however many times the client resends it, so a retried request never spends
twice.

Two implementations sit behind one port: the in-memory store the unit tests and a
bare local run use, and the relational store that is the primary database
(architecture.md "Primary Database"). A caller cannot tell them apart.

Deleting an account marks the account record and drops its entitlement, so the
token subject has no account from then on and no further lookup can spend
against it. The record is the tombstone the deletion needs, and its personal
data is hard-deleted with it once the retention window closes; the
`purge_deleted_before` pass is what carries that out (nfr.md "Data lifecycle").
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Protocol
from uuid import uuid4

from sqlalchemy import select, update
from sqlalchemy.engine import Engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .db import (
    AccountRow,
    AppliedLookupRow,
    BillingEventRow,
    EntitlementRow,
    PurchaseRow,
    create_engine,
)
from .errors import EntitlementUnavailableError
from .models import (
    EntitlementStatus,
    Plan,
    ProductKind,
    PurchaseStatus,
    StoreName,
)


@dataclass(frozen=True)
class AccountRecord:
    """A reader's account and their consent to model processing (schema "Account")."""

    id: str
    email: str
    locale: str
    consent_model_processing: bool
    consent_updated_at: str
    created_at: str
    deleted_at: str | None = None


@dataclass(frozen=True)
class EntitlementRecord:
    """A reader's plan and their allowance for the current month (schema "Entitlement").

    `renewing` is a build-layer field: it records whether a paid subscription
    continues at the period end. A cancellation or a failed payment clears it, so
    the paid period runs out before the reader reverts to free
    (monetization.md "Billing Events").
    """

    id: str
    account_id: str
    plan: Plan
    lookups_used: int
    lookups_limit: int
    period_start: str
    period_end: str
    status: EntitlementStatus
    trial_ends_at: str | None
    updated_at: str
    renewing: bool = True


@dataclass(frozen=True)
class PurchaseRecord:
    """A store purchase or refund that changed an entitlement (schema "Purchase")."""

    id: str
    account_id: str
    store: StoreName
    product_id: str
    product_kind: ProductKind
    status: PurchaseStatus
    amount_minor: int
    currency: str
    purchased_at: str
    refunded_at: str | None = None


class EntitlementStore(Protocol):
    """Port for account, entitlement, and purchase persistence."""

    async def account(self, account_id: str) -> AccountRecord | None:
        """The account with this id, or None."""
        ...

    async def create_account(self, account: AccountRecord) -> AccountRecord:
        """Create an account; an existing id is left as it is."""
        ...

    async def save_account(self, account: AccountRecord) -> AccountRecord:
        """Replace an account with the given record."""
        ...

    async def delete_account(self, account: AccountRecord) -> None:
        """Mark an account deleted and drop its entitlement."""
        ...

    async def purge_deleted_before(self, cutoff: datetime) -> int:
        """Hard-delete accounts deleted at or before the cutoff; return the count.

        Only the account record and any entitlement under it go: the record's
        personal data is what the retention window holds, the financial records
        stay for their own retention, and the shared library carries no personal
        data (nfr.md "Data lifecycle").
        """
        ...

    async def entitlement(self, account_id: str) -> EntitlementRecord | None:
        """The account's entitlement, or None."""
        ...

    async def save_entitlement(self, entitlement: EntitlementRecord) -> EntitlementRecord:
        """Replace an account's entitlement."""
        ...

    async def record_purchase(self, purchase: PurchaseRecord) -> None:
        """Add a purchase, or replace the one with the same id."""
        ...

    async def purchases_for(
        self,
        account_id: str,
        store: StoreName,
        product_id: str,
        product_kind: ProductKind,
    ) -> list[PurchaseRecord]:
        """The purchases matching a store product, oldest first."""
        ...

    async def save_purchase(self, purchase: PurchaseRecord) -> None:
        """Replace a purchase with the given record."""
        ...

    async def event_applied(self, key: str) -> bool:
        """Whether a store billing event has already been applied."""
        ...

    async def mark_event_applied(self, key: str) -> None:
        """Record that a store billing event has been applied."""
        ...

    async def lookup_applied(self, subject: str, client_lookup_id: str) -> bool:
        """Whether a lookup has already spent its allowance unit."""
        ...

    async def mark_lookup_applied(self, subject: str, client_lookup_id: str) -> None:
        """Record that a lookup has spent its allowance unit."""
        ...

    async def aclose(self) -> None:
        """Release whatever the store holds open."""
        ...


class InMemoryEntitlementStore:
    """An in-memory account, entitlement, and purchase store."""

    def __init__(self) -> None:
        self._accounts: dict[str, AccountRecord] = {}
        self._entitlements: dict[str, EntitlementRecord] = {}
        self._purchases: dict[str, PurchaseRecord] = {}
        self._applied_events: set[str] = set()
        self._applied_lookups: set[tuple[str, str]] = set()

    async def account(self, account_id: str) -> AccountRecord | None:
        return self._accounts.get(account_id)

    async def create_account(self, account: AccountRecord) -> AccountRecord:
        existing = self._accounts.get(account.id)
        if existing is not None:
            return existing
        self._accounts[account.id] = account
        return account

    async def save_account(self, account: AccountRecord) -> AccountRecord:
        self._accounts[account.id] = account
        return account

    async def delete_account(self, account: AccountRecord) -> None:
        # The account is kept as the tombstone the contract's "the token's
        # subject has no account" needs; its personal data is hard-deleted with
        # the record once the retention window closes. The entitlement goes now.
        self._accounts[account.id] = account
        self._entitlements.pop(account.id, None)

    async def purge_deleted_before(self, cutoff: datetime) -> int:
        due = [
            account_id
            for account_id, account in self._accounts.items()
            if account.deleted_at is not None and _parse_iso(account.deleted_at) <= cutoff
        ]
        for account_id in due:
            # The record and its personal data are gone for good; any entitlement
            # still under it goes too. Purchases are financial records and stay
            # for their own retention (nfr.md "Data lifecycle").
            del self._accounts[account_id]
            self._entitlements.pop(account_id, None)
        return len(due)

    async def entitlement(self, account_id: str) -> EntitlementRecord | None:
        return self._entitlements.get(account_id)

    async def save_entitlement(self, entitlement: EntitlementRecord) -> EntitlementRecord:
        self._entitlements[entitlement.account_id] = entitlement
        return entitlement

    async def record_purchase(self, purchase: PurchaseRecord) -> None:
        self._purchases[purchase.id] = purchase

    async def purchases_for(
        self,
        account_id: str,
        store: StoreName,
        product_id: str,
        product_kind: ProductKind,
    ) -> list[PurchaseRecord]:
        matches = [
            purchase
            for purchase in self._purchases.values()
            if purchase.account_id == account_id
            and purchase.store == store
            and purchase.product_id == product_id
            and purchase.product_kind == product_kind
        ]
        return sorted(matches, key=lambda purchase: purchase.purchased_at)

    async def save_purchase(self, purchase: PurchaseRecord) -> None:
        self._purchases[purchase.id] = purchase

    async def event_applied(self, key: str) -> bool:
        return key in self._applied_events

    async def mark_event_applied(self, key: str) -> None:
        self._applied_events.add(key)

    async def lookup_applied(self, subject: str, client_lookup_id: str) -> bool:
        return (subject, client_lookup_id) in self._applied_lookups

    async def mark_lookup_applied(self, subject: str, client_lookup_id: str) -> None:
        self._applied_lookups.add((subject, client_lookup_id))

    async def aclose(self) -> None:
        return None


def new_entitlement_id() -> str:
    return f"en_{uuid4().hex}"


def new_purchase_id() -> str:
    return f"pu_{uuid4().hex}"


def _parse_iso(value: str) -> datetime:
    """Parse a stored UTC ISO-8601 timestamp, normalised to UTC."""

    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat()


class PostgresEntitlementStore:
    """Accounts, entitlements, and purchases in the primary relational database.

    The tables are the platform's migration history (`infra/db/migrations`), so
    the store maps them and never creates it. Each call runs its query on a
    worker thread, so a slow database never blocks the event loop a reader's
    entitlement read or a billing webhook runs on (NFR-006). Every failure to
    reach the database is reported as the store being unavailable, so the service
    answers 503 and the client retries or reconciles later (C-018 to C-022;
    NFR-011).

    A deleted account is marked and its entitlement dropped in one step, so from
    that moment the token's subject has no account and no lookup can meter against
    it. The retention pass hard-deletes the row once the window closes; the
    account's purchases detach rather than going with it, because a financial
    record outlives the account's personal data for its own retention (nfr.md
    "Data lifecycle").

    The two idempotency ledgers are rows of their own: a billing event is
    recorded once however many times the processor redelivers it, and a lookup is
    metered once however many times the client resends it.
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine
        self._sessions: sessionmaker[Session] = sessionmaker(engine, expire_on_commit=False)

    async def account(self, account_id: str) -> AccountRecord | None:
        return await asyncio.to_thread(self._account, account_id)

    async def create_account(self, account: AccountRecord) -> AccountRecord:
        return await asyncio.to_thread(self._create_account, account)

    async def save_account(self, account: AccountRecord) -> AccountRecord:
        return await asyncio.to_thread(self._save_account, account)

    async def delete_account(self, account: AccountRecord) -> None:
        await asyncio.to_thread(self._delete_account, account)

    async def purge_deleted_before(self, cutoff: datetime) -> int:
        return await asyncio.to_thread(self._purge_deleted_before, cutoff)

    async def entitlement(self, account_id: str) -> EntitlementRecord | None:
        return await asyncio.to_thread(self._entitlement, account_id)

    async def save_entitlement(self, entitlement: EntitlementRecord) -> EntitlementRecord:
        return await asyncio.to_thread(self._save_entitlement, entitlement)

    async def record_purchase(self, purchase: PurchaseRecord) -> None:
        await asyncio.to_thread(self._write_purchase, purchase)

    async def purchases_for(
        self,
        account_id: str,
        store: StoreName,
        product_id: str,
        product_kind: ProductKind,
    ) -> list[PurchaseRecord]:
        return await asyncio.to_thread(
            self._purchases_for, account_id, store, product_id, product_kind
        )

    async def save_purchase(self, purchase: PurchaseRecord) -> None:
        await asyncio.to_thread(self._write_purchase, purchase)

    async def event_applied(self, key: str) -> bool:
        return await asyncio.to_thread(self._event_applied, key)

    async def mark_event_applied(self, key: str) -> None:
        await asyncio.to_thread(self._mark_event_applied, key)

    async def lookup_applied(self, subject: str, client_lookup_id: str) -> bool:
        return await asyncio.to_thread(self._lookup_applied, subject, client_lookup_id)

    async def mark_lookup_applied(self, subject: str, client_lookup_id: str) -> None:
        await asyncio.to_thread(self._mark_lookup_applied, subject, client_lookup_id)

    async def aclose(self) -> None:
        await asyncio.to_thread(self._engine.dispose)

    # --- synchronous bodies, each run on a worker thread ----------------------

    def _account(self, account_id: str) -> AccountRecord | None:
        try:
            with self._sessions() as session:
                row = session.get(AccountRow, account_id)
                return None if row is None else _account_record(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _create_account(self, account: AccountRecord) -> AccountRecord:
        try:
            with self._sessions() as session, session.begin():
                existing = session.get(AccountRow, account.id)
                if existing is not None:
                    # An existing id is left as it is, so a second sign-in on the
                    # same subject never overwrites the account's choices.
                    return _account_record(existing)
                session.add(_account_row(account))
                return account
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _save_account(self, account: AccountRecord) -> AccountRecord:
        try:
            with self._sessions() as session, session.begin():
                row = session.get(AccountRow, account.id)
                if row is None:
                    session.add(_account_row(account))
                else:
                    _apply_account(row, account)
                return account
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _delete_account(self, account: AccountRecord) -> None:
        try:
            with self._sessions() as session, session.begin():
                row = session.get(AccountRow, account.id)
                if row is None:
                    session.add(_account_row(account))
                else:
                    _apply_account(row, account)
                entitlement = session.scalar(
                    select(EntitlementRow).where(EntitlementRow.account_id == account.id)
                )
                if entitlement is not None:
                    session.delete(entitlement)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _purge_deleted_before(self, cutoff: datetime) -> int:
        # The timestamps are the store's own UTC ISO-8601 text, so the comparison
        # is the same instant ordering the in-memory store computes from parsed
        # datetimes.
        cutoff_iso = _iso(cutoff)
        try:
            with self._sessions() as session, session.begin():
                due = session.scalars(
                    select(AccountRow).where(
                        AccountRow.deleted_at.is_not(None),
                        AccountRow.deleted_at <= cutoff_iso,
                    )
                ).all()
                account_ids = [row.id for row in due]
                if not account_ids:
                    return 0
                # The entitlement goes with the record; the purchases detach, so a
                # financial record survives its account's personal data for its
                # own retention. The detach is explicit rather than left to the
                # foreign key, so it holds wherever the schema is applied.
                for entitlement in session.scalars(
                    select(EntitlementRow).where(EntitlementRow.account_id.in_(account_ids))
                ).all():
                    session.delete(entitlement)
                session.execute(
                    update(PurchaseRow)
                    .where(PurchaseRow.account_id.in_(account_ids))
                    .values(account_id=None)
                )
                session.flush()
                for row in due:
                    session.delete(row)
                return len(due)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _entitlement(self, account_id: str) -> EntitlementRecord | None:
        try:
            with self._sessions() as session:
                row = session.scalar(
                    select(EntitlementRow).where(EntitlementRow.account_id == account_id)
                )
                return None if row is None else _entitlement_record(row)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _save_entitlement(self, entitlement: EntitlementRecord) -> EntitlementRecord:
        try:
            with self._sessions() as session, session.begin():
                row = session.scalar(
                    select(EntitlementRow).where(
                        EntitlementRow.account_id == entitlement.account_id
                    )
                )
                if row is None:
                    session.add(_entitlement_row(entitlement))
                else:
                    _apply_entitlement(row, entitlement)
                return entitlement
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _write_purchase(self, purchase: PurchaseRecord) -> None:
        try:
            with self._sessions() as session, session.begin():
                row = session.get(PurchaseRow, purchase.id)
                if row is None:
                    session.add(_purchase_row(purchase))
                else:
                    _apply_purchase(row, purchase)
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _purchases_for(
        self,
        account_id: str,
        store: StoreName,
        product_id: str,
        product_kind: ProductKind,
    ) -> list[PurchaseRecord]:
        try:
            with self._sessions() as session:
                rows = session.scalars(
                    select(PurchaseRow)
                    .where(
                        PurchaseRow.account_id == account_id,
                        PurchaseRow.store == store.value,
                        PurchaseRow.product_id == product_id,
                        PurchaseRow.product_kind == product_kind.value,
                    )
                    .order_by(PurchaseRow.purchased_at)
                ).all()
                return [_purchase_record(row) for row in rows]
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _event_applied(self, key: str) -> bool:
        try:
            with self._sessions() as session:
                return session.get(BillingEventRow, key) is not None
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _mark_event_applied(self, key: str) -> None:
        try:
            with self._sessions() as session, session.begin():
                if session.get(BillingEventRow, key) is None:
                    session.add(BillingEventRow(key=key, applied_at=_now()))
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _lookup_applied(self, subject: str, client_lookup_id: str) -> bool:
        try:
            with self._sessions() as session:
                return session.get(AppliedLookupRow, (subject, client_lookup_id)) is not None
        except SQLAlchemyError as exc:
            raise _unavailable() from exc

    def _mark_lookup_applied(self, subject: str, client_lookup_id: str) -> None:
        try:
            with self._sessions() as session, session.begin():
                if session.get(AppliedLookupRow, (subject, client_lookup_id)) is None:
                    session.add(
                        AppliedLookupRow(
                            subject=subject,
                            client_lookup_id=client_lookup_id,
                            applied_at=_now(),
                        )
                    )
        except SQLAlchemyError as exc:
            raise _unavailable() from exc


def build_default_store(settings: Settings) -> EntitlementStore:
    """The store the service runs on: the primary database when one is configured.

    An empty `DATABASE_URL` resolves to the in-memory store, which the unit tests
    and a bare local run use; every deployed environment supplies it.
    """

    if settings.database_url is None:
        return InMemoryEntitlementStore()
    return PostgresEntitlementStore(create_engine(settings.database_url))


def _account_row(account: AccountRecord) -> AccountRow:
    return AccountRow(
        id=account.id,
        email=account.email,
        locale=account.locale,
        consent_model_processing=account.consent_model_processing,
        consent_updated_at=account.consent_updated_at,
        created_at=account.created_at,
        deleted_at=account.deleted_at,
    )


def _apply_account(row: AccountRow, account: AccountRecord) -> None:
    row.email = account.email
    row.locale = account.locale
    row.consent_model_processing = account.consent_model_processing
    row.consent_updated_at = account.consent_updated_at
    row.created_at = account.created_at
    row.deleted_at = account.deleted_at


def _account_record(row: AccountRow) -> AccountRecord:
    return AccountRecord(
        id=row.id,
        email=row.email,
        locale=row.locale,
        consent_model_processing=bool(row.consent_model_processing),
        consent_updated_at=row.consent_updated_at or "",
        created_at=row.created_at,
        deleted_at=row.deleted_at,
    )


def _entitlement_row(entitlement: EntitlementRecord) -> EntitlementRow:
    return EntitlementRow(
        id=entitlement.id,
        account_id=entitlement.account_id,
        plan=entitlement.plan.value,
        trial_ends_at=entitlement.trial_ends_at,
        renewing=entitlement.renewing,
        lookups_used=entitlement.lookups_used,
        lookups_limit=entitlement.lookups_limit,
        period_start=entitlement.period_start,
        period_end=entitlement.period_end,
        status=entitlement.status.value,
        updated_at=entitlement.updated_at,
    )


def _apply_entitlement(row: EntitlementRow, entitlement: EntitlementRecord) -> None:
    row.plan = entitlement.plan.value
    row.trial_ends_at = entitlement.trial_ends_at
    row.renewing = entitlement.renewing
    row.lookups_used = entitlement.lookups_used
    row.lookups_limit = entitlement.lookups_limit
    row.period_start = entitlement.period_start
    row.period_end = entitlement.period_end
    row.status = entitlement.status.value
    row.updated_at = entitlement.updated_at


def _entitlement_record(row: EntitlementRow) -> EntitlementRecord:
    return EntitlementRecord(
        id=row.id,
        account_id=row.account_id,
        plan=Plan(row.plan),
        lookups_used=row.lookups_used,
        lookups_limit=row.lookups_limit,
        period_start=row.period_start,
        period_end=row.period_end,
        status=EntitlementStatus(row.status),
        trial_ends_at=row.trial_ends_at,
        updated_at=row.updated_at,
        renewing=bool(row.renewing),
    )


def _purchase_row(purchase: PurchaseRecord) -> PurchaseRow:
    return PurchaseRow(
        id=purchase.id,
        account_id=purchase.account_id,
        store=purchase.store.value,
        product_id=purchase.product_id,
        product_kind=purchase.product_kind.value,
        status=purchase.status.value,
        amount_minor=purchase.amount_minor,
        currency=purchase.currency,
        purchased_at=purchase.purchased_at,
        refunded_at=purchase.refunded_at,
    )


def _apply_purchase(row: PurchaseRow, purchase: PurchaseRecord) -> None:
    row.account_id = purchase.account_id
    row.store = purchase.store.value
    row.product_id = purchase.product_id
    row.product_kind = purchase.product_kind.value
    row.status = purchase.status.value
    row.amount_minor = purchase.amount_minor
    row.currency = purchase.currency
    row.purchased_at = purchase.purchased_at
    row.refunded_at = purchase.refunded_at


def _purchase_record(row: PurchaseRow) -> PurchaseRecord:
    return PurchaseRecord(
        id=row.id,
        # A detached purchase (its account's personal data was purged) is only
        # reachable through the account that made it, so it is never read back
        # under a null account.
        account_id=row.account_id or "",
        store=StoreName(row.store),
        product_id=row.product_id,
        product_kind=ProductKind(row.product_kind),
        status=PurchaseStatus(row.status),
        amount_minor=row.amount_minor,
        currency=row.currency,
        purchased_at=row.purchased_at,
        refunded_at=row.refunded_at,
    )


def _unavailable() -> EntitlementUnavailableError:
    return EntitlementUnavailableError("The account store is unavailable. Please try again.")


def _now() -> str:
    return datetime.now(UTC).isoformat()

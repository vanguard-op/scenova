"""Relational persistence for accounts, entitlements, and purchases (FEAT-013).

The account and entitlement store is the primary database's relational half
(architecture.md "Data Architecture": accounts and entitlements): one `accounts`
row per reader, one `entitlements` row per account for the current allowance
period, and one `purchases` row per store purchase or refund (schema.md
"Account", "Entitlement", "Purchase").

An account is keyed by the reader's identity subject, which is the same across
the reader's devices, so a sign-in on a new device finds the same account and the
entitlement follows it. The email and the locale are personal data (schema
"Account"), so a deletion marks the row and drops its entitlement at once and the
retention pass hard-deletes the row once the documented window closes (nfr.md
"Privacy & Compliance"). A purchase is a financial record and outlives the
account's personal data for its own retention (nfr.md "Data lifecycle"), so
`purchases.account_id` is nullable and detaches when the account goes.

Two idempotency ledgers sit beside the entities. A store billing event is
recorded once however many times the processor redelivers its webhook, and a
lookup is metered once however many times the client resends it, so a retried
request never spends twice. Neither is a `schema.md` entity, so the schema does
not name them; they are the build layer's own bookkeeping and are declared here
with the entities the store maps.

The tables are the platform's migration history (`infra/db/migrations`, applied
by `make db-migrate` locally and by the migration job in the cloud); the classes
here map that schema for reads and writes and never create it. A table that is
missing or unreachable surfaces as the entitlement store being unavailable, not
as a schema the service invents.
"""

from __future__ import annotations

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy import create_engine as _create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Base for the account and entitlement service's relational tables."""


class AccountRow(Base):
    """A reader's account and their consent to model processing (schema "Account")."""

    __tablename__ = "accounts"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    email: Mapped[str] = mapped_column(Text)
    locale: Mapped[str] = mapped_column(Text)
    consent_model_processing: Mapped[bool] = mapped_column(Boolean)
    consent_updated_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(Text)
    # Set when the account is deleted; the row is the tombstone the contract's
    # "the token's subject has no account" needs until the window closes.
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class EntitlementRow(Base):
    """A reader's plan and their allowance for the current period (schema "Entitlement")."""

    __tablename__ = "entitlements"
    __table_args__ = (
        # Each account holds one entitlement for the current period.
        UniqueConstraint("account_id", name="uq_entitlements_account"),
    )

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    account_id: Mapped[str] = mapped_column(Text, ForeignKey("accounts.id", ondelete="CASCADE"))
    plan: Mapped[str] = mapped_column(Text)
    # The C-018 `trialEndsAt`: null unless the plan is trial.
    trial_ends_at: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Whether a paid subscription continues at the period end, so a cancellation
    # or a failed payment lets the paid period run out before the reader reverts
    # to free (monetization.md "Billing Events").
    renewing: Mapped[bool] = mapped_column(Boolean)
    lookups_used: Mapped[int] = mapped_column(Integer)
    lookups_limit: Mapped[int] = mapped_column(Integer)
    period_start: Mapped[str] = mapped_column(Text)
    period_end: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text)
    updated_at: Mapped[str] = mapped_column(Text)


class PurchaseRow(Base):
    """A store purchase or refund that changed an entitlement (schema "Purchase").

    `account_id` is nullable so the account's personal data can be hard-deleted
    while the financial record stays on file for its own retention (nfr.md "Data
    lifecycle"). The retention pass detaches the row explicitly before the account
    goes, so the row is never reached by the account's cascade.
    """

    __tablename__ = "purchases"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    account_id: Mapped[str | None] = mapped_column(
        Text, ForeignKey("accounts.id", ondelete="CASCADE"), nullable=True
    )
    store: Mapped[str] = mapped_column(Text)
    product_id: Mapped[str] = mapped_column(Text)
    product_kind: Mapped[str] = mapped_column(Text)
    status: Mapped[str] = mapped_column(Text)
    amount_minor: Mapped[int] = mapped_column(Integer)
    currency: Mapped[str] = mapped_column(Text)
    purchased_at: Mapped[str] = mapped_column(Text)
    refunded_at: Mapped[str | None] = mapped_column(Text, nullable=True)


class BillingEventRow(Base):
    """One store billing event already applied, so a redelivery applies once."""

    __tablename__ = "billing_events"

    # The natural key of the event: the account, the event, the store product,
    # and when it occurred (C-019).
    key: Mapped[str] = mapped_column(Text, primary_key=True)
    applied_at: Mapped[str] = mapped_column(String(64))


class AppliedLookupRow(Base):
    """One lookup already metered, so a resent create spends once."""

    __tablename__ = "applied_lookups"

    subject: Mapped[str] = mapped_column(Text, primary_key=True)
    client_lookup_id: Mapped[str] = mapped_column(Text, primary_key=True)
    applied_at: Mapped[str] = mapped_column(String(64))


def create_engine(database_url: str) -> Engine:
    """A relational engine for the primary database.

    The engine connects lazily, so the service starts and serves `/healthz`
    whether or not the database is up; a store call that cannot reach it raises
    the entitlement store's unavailable error, so the service answers 503 and the
    client retries (C-018 to C-022) or reconciles later (NFR-011). The store
    offloads each call to a worker thread, so a slow query never blocks the event
    loop a reader's entitlement read or a billing webhook runs on (NFR-006).
    `pool_pre_ping` discards a connection the database has dropped, so a failover
    is transparent to the next call rather than a spurious 503.
    """

    return _create_engine(database_url, pool_pre_ping=True)

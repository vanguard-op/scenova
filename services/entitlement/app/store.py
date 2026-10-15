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

The store is in memory for this phase; Cloud SQL replaces it behind the same
port, holding the same entities, so no caller changes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol
from uuid import uuid4

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


def new_entitlement_id() -> str:
    return f"en_{uuid4().hex}"


def new_purchase_id() -> str:
    return f"pu_{uuid4().hex}"

"""Wire models for the account and entitlement service (C-018 to C-021).

The stored records are the `schema.md` entities "Account", "Entitlement", and
"Purchase". The entitlement carries two fields the schema does not name: the
`trialEndsAt` the contract exposes (C-018) and an internal `renewing` flag that
records whether a paid subscription continues at the period end, so a
cancellation or a failed payment lets the paid period run out before the reader
reverts to free (monetization.md "Billing Events").

The internal metering seam (the lookup path's check-and-spend) is not a numbered
contract: the lookup service is its only caller.
"""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class Plan(StrEnum):
    """A reader's plan (schema "Entitlement")."""

    FREE = "free"
    TRIAL = "trial"
    PRO = "pro"


class EntitlementStatus(StrEnum):
    """The entitlement's state (schema "Entitlement").

    `active` is a plan in force for the current period; `grace` is a paid
    subscription that has lapsed — cancelled or a failed payment — while the
    paid period runs out; `expired` is a lapsed paid plan that has reverted to
    the free allowance.
    """

    ACTIVE = "active"
    GRACE = "grace"
    EXPIRED = "expired"


class BillingEvent(StrEnum):
    """A store billing event (C-019 `event`)."""

    PURCHASE = "purchase"
    RENEWAL = "renewal"
    CANCELLATION = "cancellation"
    REFUND = "refund"
    FAILED_PAYMENT = "failed_payment"


class StoreName(StrEnum):
    """The store that handled a purchase (schema "Purchase")."""

    APP_STORE = "app_store"
    PLAY_STORE = "play_store"


class ProductKind(StrEnum):
    """Whether a purchase is a subscription or a lookup top-up (schema "Purchase")."""

    SUBSCRIPTION = "subscription"
    TOPUP = "topup"


class PurchaseStatus(StrEnum):
    """A purchase's state (schema "Purchase")."""

    ACTIVE = "active"
    REFUNDED = "refunded"
    FAILED = "failed"


class EntitlementResponse(BaseModel):
    """The C-018 response: the reader's plan and their allowance for the month."""

    model_config = ConfigDict(extra="forbid")

    plan: Plan
    lookupsUsed: int
    lookupsLimit: int
    periodStart: str
    periodEnd: str
    status: EntitlementStatus
    trialEndsAt: str | None


class AccountUpdateRequest(BaseModel):
    """The C-020 request: the consent choice, the locale, or both.

    Both fields are optional in shape; the contract's rule that at least one is
    given is enforced by the service, so the 400 has one owner.
    """

    model_config = ConfigDict(extra="forbid")

    consentModelProcessing: bool | None = None
    locale: str | None = None


class AccountResponse(BaseModel):
    """The C-020 response: the account's consent choice and locale."""

    model_config = ConfigDict(extra="forbid")

    consentModelProcessing: bool
    locale: str


class DeleteAccountResponse(BaseModel):
    """The C-021 response: the account was deleted."""

    model_config = ConfigDict(extra="forbid")

    deleted: bool


class PurgeResponse(BaseModel):
    """The retention pass's outcome: how many deleted accounts were hard-deleted.

    The purge is an internal governance seam rather than a numbered contract, like
    the analytics intake's retention pass: a scheduled caller runs it, and the
    count is its report.
    """

    model_config = ConfigDict(extra="forbid")

    purged: int


class EntitlementSyncRequest(BaseModel):
    """The C-019 request: one signed store billing event."""

    model_config = ConfigDict(extra="forbid")

    accountId: str = Field(min_length=1)
    event: BillingEvent
    store: StoreName
    productId: str = Field(min_length=1)
    productKind: ProductKind
    amountMinor: int = Field(ge=0)
    currency: str = Field(min_length=1)
    occurredAt: str = Field(min_length=1)


class SyncResponse(BaseModel):
    """The C-019 response: whether the event changed the entitlement."""

    model_config = ConfigDict(extra="forbid")

    applied: bool


class SpendRequest(BaseModel):
    """One lookup's check-and-spend against a reader's allowance.

    The lookup service calls this before it serves or generates, so a lookup
    that resolves to the fallback has spent nothing.
    """

    model_config = ConfigDict(extra="forbid")

    subject: str = Field(min_length=1)
    clientLookupId: str | None = None


class SpendResponse(BaseModel):
    """The allowance after a lookup: whether it may proceed, and the C-001 meter."""

    model_config = ConfigDict(extra="forbid")

    allowed: bool
    plan: Plan
    lookupsUsed: int
    lookupsLimit: int
    periodEnd: str

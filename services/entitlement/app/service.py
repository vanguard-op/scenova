"""The account, the entitlement, and the lookup meter (FEAT-013).

`entitlement` resolves a signed-in reader's plan and allowance for the current
period (C-018). An account is created the first time a signed-in reader is seen;
an anonymous token has no account and is refused, because before sign-in the
reader is metered on the device and carries no allowance here.

`update_account` stores the reader's consent choice and locale on the account, so
the choice follows them to a new device (C-020). Before sign-in the client holds
both on the device alone and never reaches this service.

`account_settings` reads that choice and locale back from the account (C-022), so
a reader who made them on one device finds them on another. It reads the same
account `update_account` writes, and refuses an anonymous or deleted token the
same way.

`delete_account` removes the reader's account and its entitlement (C-021): the
account is marked deleted and the entitlement dropped, so the token's subject has
no account from then on and the reader is a new reader with no account. The
shared library is untouched; the personal data is hard-deleted within the
documented window.

`sync` applies one signed store billing event (C-019): a subscription sets the
plan and the allowance period, a top-up adds its lookups to the current period
and does not carry over, a refund removes the entitlement, and a cancellation or
a failed payment lets the paid period run out before the reader reverts to free.

`spend` is the lookup path's check-and-spend: one lookup spends one unit of the
allowance whether it is served or generated, and a lookup with nothing left is
refused without spending so it resolves to the fallback. It is an internal seam,
not a numbered contract.

`purge_deleted_accounts` is the retention pass: a deleted account's record and
its personal data are hard-deleted once the documented window closes (nfr.md
"Data lifecycle"). It is an internal seam, not a numbered contract.

The `enable_paid_tier` release flag (release.md "Rollout Phases & Feature
Flags") is applied when a reader is served or metered: when it is off, every
reader is served as Free, whatever their stored plan. The stored entitlement is
left as it is, so flipping the flag back on restores the reader's plan rather
than forcing them to buy it again.

A period rolls forward on any access, so a reader who has not opened the app for
a month is metered against the month they are in, not the one they left. A
top-up is deliberately not carried into the new period.
"""

from __future__ import annotations

import asyncio
import calendar
import logging
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta

from .auth import Subject
from .errors import (
    AccountNotFoundError,
    InvalidRequestError,
    NoAccountError,
    UnknownLocaleError,
)
from .locales import normalise_locale
from .models import (
    AccountResponse,
    AccountUpdateRequest,
    BillingEvent,
    DeleteAccountResponse,
    EntitlementResponse,
    EntitlementStatus,
    EntitlementSyncRequest,
    Plan,
    ProductKind,
    PurchaseStatus,
    SpendResponse,
    SyncResponse,
)
from .store import (
    AccountRecord,
    EntitlementRecord,
    EntitlementStore,
    PurchaseRecord,
    new_entitlement_id,
    new_purchase_id,
)

logger = logging.getLogger(__name__)

# The locale a new account starts on. branding.md "Launch locales" ships the
# English UI at v1; the reader can change it in Preferences.
DEFAULT_LOCALE = "en"


class EntitlementService:
    """Resolves plans and allowances, and applies store billing events."""

    def __init__(
        self,
        *,
        store: EntitlementStore,
        free_lookups: int,
        pro_lookups: int,
        topup_lookups: int,
        trial_days: int,
        retention_days: int,
        paid_tier_enabled: bool = True,
        clock: Callable[[], datetime] | None = None,
    ) -> None:
        self._store = store
        self._free_lookups = max(0, free_lookups)
        self._pro_lookups = max(0, pro_lookups)
        self._topup_lookups = max(0, topup_lookups)
        self._trial_days = max(0, trial_days)
        self._retention_days = max(0, retention_days)
        self._paid_tier_enabled = paid_tier_enabled
        self._clock = clock if clock is not None else _utcnow
        # Serialises the read-modify-write of an allowance, so two lookups racing
        # for the last unit cannot both spend it and a redelivered event is
        # applied once.
        self._write_lock = asyncio.Lock()

    async def entitlement(self, subject: Subject) -> EntitlementResponse:
        """The reader's plan and allowance for the current period (C-018)."""

        account = await self._account_for(subject)
        record = await self._entitlement_for(account)
        return _response(self._served(record))

    async def account_settings(self, subject: Subject) -> AccountResponse:
        """The reader's stored consent choice and locale (C-022).

        Both live on the account the reader's identity subject owns, so a choice
        made on one device reads back here on another (FEAT-012). A reader who is
        not signed in holds both on the device and never reaches this: an
        anonymous token has no account, which is the contract's 401.
        """

        account = await self._account_for(
            subject,
            no_account_message="Sign in to read the choices saved on your account.",
        )
        return AccountResponse(
            consentModelProcessing=account.consent_model_processing,
            locale=account.locale,
        )

    async def update_account(
        self, subject: Subject, request: AccountUpdateRequest
    ) -> AccountResponse:
        """Store the reader's consent choice and locale (C-020)."""

        if request.consentModelProcessing is None and request.locale is None:
            raise InvalidRequestError("Provide consentModelProcessing or locale.")

        account = await self._account_for(subject)
        locale = account.locale
        consent = account.consent_model_processing
        consent_updated_at = account.consent_updated_at
        if request.locale is not None:
            resolved_locale = normalise_locale(request.locale)
            if resolved_locale is None:
                raise UnknownLocaleError("That language is not one Scenova offers.")
            locale = resolved_locale
        if request.consentModelProcessing is not None:
            consent = request.consentModelProcessing
            consent_updated_at = _iso(self._clock())

        updated = await self._store.save_account(
            replace(
                account,
                locale=locale,
                consent_model_processing=consent,
                consent_updated_at=consent_updated_at,
            )
        )
        return AccountResponse(
            consentModelProcessing=updated.consent_model_processing,
            locale=updated.locale,
        )

    async def delete_account(self, subject: Subject) -> DeleteAccountResponse:
        """Delete the reader's account and its entitlement (C-021).

        The account is marked deleted and the entitlement dropped in one store
        step, so from that moment the token's subject has no account and no
        further lookup can meter against it. The reader's personal data is
        hard-deleted with the record once the retention window closes (nfr.md
        "Data lifecycle"); the shared library is untouched. The store's step is
        serialised with metering, so a lookup cannot spend against an account
        that is being deleted.

        A token with no account — anonymous before sign-in, or one whose account
        is already gone — is the contract's 401; deletion never creates one.
        """

        if subject.is_anonymous:
            raise NoAccountError("Sign in to delete your account.")
        async with self._write_lock:
            account = await self._store.account(subject.id)
            if account is None or account.deleted_at is not None:
                raise NoAccountError("This account no longer exists.")
            await self._store.delete_account(replace(account, deleted_at=_iso(self._clock())))
        return DeleteAccountResponse(deleted=True)

    async def purge_deleted_accounts(self, now: datetime | None = None) -> int:
        """Hard-delete accounts past the retention window (nfr.md "Data lifecycle").

        A deleted account is a tombstone until the window closes: the reader is
        signed out and no lookup meters against it, but the record still holds
        their email and locale. Once the window has closed the record and its
        personal data are hard-deleted, so the deletion request is honoured within
        the documented 30 days. The financial records and the shared library are
        left as they are.

        The pass is idempotent: it is a scheduled job, so running it again finds
        nothing due and reports zero.
        """

        moment = now if now is not None else self._clock()
        cutoff = moment - timedelta(days=self._retention_days)
        async with self._write_lock:
            purged = await self._store.purge_deleted_before(cutoff)
        if purged:
            logger.info("hard-deleted %d accounts past the retention window", purged)
        return purged

    async def sync(self, request: EntitlementSyncRequest) -> SyncResponse:
        """Apply one signed store billing event (C-019).

        The processor redelivers a webhook until it is acknowledged, so an event
        that has already been applied is accepted without a second effect.
        `applied` is whether the event changed the entitlement.
        """

        key = _event_key(request)
        async with self._write_lock:
            if await self._store.event_applied(key):
                return SyncResponse(applied=False)

            account = await self._store.account(request.accountId)
            if account is None:
                raise AccountNotFoundError("No account exists for this id.")

            record = await self._entitlement_for(account)
            occurred = _parse_occurred(request.occurredAt)
            now = self._clock()
            updated = self._apply_event(record, request, occurred=occurred, now=now)
            await self._store.save_entitlement(updated)
            await self._record_purchase(request, occurred=occurred, now=now)
            await self._store.mark_event_applied(key)
            return SyncResponse(applied=updated != record)

    async def spend(self, subject: Subject, client_lookup_id: str | None) -> SpendResponse:
        """Check and spend one unit of the reader's allowance.

        A lookup with nothing left is refused without spending, so the caller can
        resolve it to the fallback with `used` equal to `limit`. A lookup the
        client resends with the same key is metered once.

        The spend is against the allowance the reader is served — Free while the
        paid tier is off — while the stored record keeps counting, so re-enabling
        the tier finds the month's usage intact.
        """

        account = await self._account_for(subject)
        async with self._write_lock:
            record = await self._entitlement_for(account)
            if client_lookup_id is not None and await self._store.lookup_applied(
                subject.id, client_lookup_id
            ):
                return _spend_response(self._served(record), allowed=True)
            served = self._served(record)
            if served.lookups_used >= served.lookups_limit:
                return _spend_response(served, allowed=False)
            updated = replace(
                record,
                lookups_used=record.lookups_used + 1,
                updated_at=_iso(self._clock()),
            )
            await self._store.save_entitlement(updated)
            if client_lookup_id is not None:
                await self._store.mark_lookup_applied(subject.id, client_lookup_id)
            return _spend_response(self._served(updated), allowed=True)

    async def aclose(self) -> None:
        """Release whatever the store holds open."""

        await self._store.aclose()

    # --- Accounts and entitlements -------------------------------------------

    async def _account_for(
        self,
        subject: Subject,
        *,
        no_account_message: str = "Sign in to see your plan and allowance.",
    ) -> AccountRecord:
        """The reader's account, created on first sight, or 401 when unsigned.

        An anonymous token belongs to a reader who has not signed in; their
        allowance is device-local, so there is no account to meter and the
        contract's 401 applies (C-018, C-020, C-022). The message names what the
        caller was asking for, so each read or write refuses in its own words.
        """

        if subject.is_anonymous:
            raise NoAccountError(no_account_message)

        account = await self._store.account(subject.id)
        if account is not None and account.deleted_at is not None:
            # A deleted account is a tombstone: the reader is signed out and has
            # no account, and one is never recreated behind the deletion.
            raise NoAccountError("This account no longer exists.")
        if account is None:
            now = _iso(self._clock())
            account = await self._store.create_account(
                AccountRecord(
                    id=subject.id,
                    email=subject.email or "",
                    locale=DEFAULT_LOCALE,
                    consent_model_processing=False,
                    consent_updated_at=now,
                    created_at=now,
                )
            )
        return account

    async def _entitlement_for(self, account: AccountRecord) -> EntitlementRecord:
        """The account's entitlement for the current period, created if absent."""

        record = await self._store.entitlement(account.id)
        if record is None:
            record = await self._store.save_entitlement(self._new_entitlement(account))
        return await self._reconciled(record)

    def _new_entitlement(self, account: AccountRecord) -> EntitlementRecord:
        """A new account's entitlement: the 7-day Pro trial, then Free.

        monetization.md "Trial Period": the trial is at sign-up with no card, and
        it carries the Pro allowance for its length.
        """

        now = self._clock()
        trial_ends = now + timedelta(days=self._trial_days) if self._trial_days > 0 else None
        plan = Plan.TRIAL if trial_ends is not None else Plan.FREE
        return EntitlementRecord(
            id=new_entitlement_id(),
            account_id=account.id,
            plan=plan,
            lookups_used=0,
            lookups_limit=self._limit_for(plan),
            period_start=_iso(now),
            period_end=_iso(_add_month(now)),
            status=EntitlementStatus.ACTIVE,
            trial_ends_at=_iso(trial_ends) if trial_ends is not None else None,
            updated_at=_iso(now),
        )

    async def _reconciled(self, record: EntitlementRecord) -> EntitlementRecord:
        """Bring an entitlement up to now: end the trial, roll the period.

        The trial ends by date; the allowance period rolls at its boundary. A
        lapsed paid plan reverts to Free at the boundary and reads `expired` for
        the period that follows.
        """

        now = self._clock()
        updated = record

        if (
            updated.plan is Plan.TRIAL
            and updated.trial_ends_at is not None
            and now >= _parse(updated.trial_ends_at)
        ):
            updated = replace(
                updated,
                plan=Plan.FREE,
                lookups_limit=self._free_lookups,
                status=EntitlementStatus.ACTIVE,
                trial_ends_at=None,
                updated_at=_iso(now),
            )

        if now < _parse(updated.period_end):
            return updated if updated == record else await self._store.save_entitlement(updated)

        # Roll to the period that holds now; a gap of several months rolls the
        # whole way in one step, and the top-up bought in an earlier period does
        # not carry into this one (monetization.md "Lookup Top-Up").
        start = _parse(updated.period_start)
        end = _parse(updated.period_end)
        while now >= end:
            start = end
            end = _add_month(end)

        plan = updated.plan
        status = EntitlementStatus.ACTIVE
        if plan is Plan.PRO and not updated.renewing:
            plan = Plan.FREE
            status = EntitlementStatus.EXPIRED
        rolled = replace(
            updated,
            plan=plan,
            lookups_used=0,
            lookups_limit=self._limit_for(plan),
            period_start=_iso(start),
            period_end=_iso(end),
            status=status,
            updated_at=_iso(now),
        )
        return await self._store.save_entitlement(rolled)

    def _limit_for(self, plan: Plan) -> int:
        return self._free_lookups if plan is Plan.FREE else self._pro_lookups

    def _served(self, record: EntitlementRecord) -> EntitlementRecord:
        """The entitlement a reader is served and metered on right now.

        With the paid tier live this is the stored entitlement. With the
        `enable_paid_tier` kill switch off it is Free: the plan reads free, the
        allowance is the Free allowance, the trial is not offered and the period
        reads active, so an exhausted allowance shows the word and phrase with no
        plan to buy (release.md "Rollout Phases & Feature Flags").

        The override is a serve-time view, never a write: the trial, the paid
        plan, and the month's usage stay in the store, so re-enabling the tier
        restores the reader's plan and their usage rather than making them buy it
        again. The used count is clamped to the Free allowance so an exhausted
        meter reads `used` equal to `limit`, which the client relies on (C-001).
        """

        if self._paid_tier_enabled:
            return record
        return replace(
            record,
            plan=Plan.FREE,
            lookups_used=min(record.lookups_used, self._free_lookups),
            lookups_limit=self._free_lookups,
            status=EntitlementStatus.ACTIVE,
            trial_ends_at=None,
        )

    # --- Billing events -------------------------------------------------------

    def _apply_event(
        self,
        record: EntitlementRecord,
        request: EntitlementSyncRequest,
        *,
        occurred: datetime,
        now: datetime,
    ) -> EntitlementRecord:
        event = request.event
        kind = request.productKind

        if event in (BillingEvent.PURCHASE, BillingEvent.RENEWAL):
            if kind is ProductKind.SUBSCRIPTION:
                return self._apply_subscription(record, occurred=occurred, now=now)
            if event is BillingEvent.PURCHASE:
                return self._apply_topup(record, now=now)
            raise InvalidRequestError("A renewal applies to a subscription, not a top-up.")

        if event in (BillingEvent.CANCELLATION, BillingEvent.FAILED_PAYMENT):
            if kind is not ProductKind.SUBSCRIPTION:
                raise InvalidRequestError(
                    "A cancellation or a failed payment applies to a subscription."
                )
            return self._apply_lapse(record, now=now)

        if event is BillingEvent.REFUND:
            if kind is ProductKind.TOPUP:
                return self._apply_topup_refund(record, now=now)
            return self._apply_refund(record, now=now)

        raise InvalidRequestError("Unknown billing event.")

    def _apply_subscription(
        self, record: EntitlementRecord, *, occurred: datetime, now: datetime
    ) -> EntitlementRecord:
        """A purchase or renewal sets the plan and a fresh allowance period.

        monetization.md "Upgrade": effective at once, so the Pro allowance
        applies from the event rather than the next month.
        """

        start = occurred if occurred <= now else now
        return replace(
            record,
            plan=Plan.PRO,
            lookups_used=0,
            lookups_limit=self._pro_lookups,
            period_start=_iso(start),
            period_end=_iso(_add_month(start)),
            status=EntitlementStatus.ACTIVE,
            trial_ends_at=None,
            renewing=True,
            updated_at=_iso(now),
        )

    def _apply_topup(self, record: EntitlementRecord, *, now: datetime) -> EntitlementRecord:
        """A top-up adds its lookups to the current period; it does not carry over."""

        return replace(
            record,
            lookups_limit=record.lookups_limit + self._topup_lookups,
            updated_at=_iso(now),
        )

    def _apply_topup_refund(self, record: EntitlementRecord, *, now: datetime) -> EntitlementRecord:
        """A refunded top-up takes its lookups back, never below what was spent."""

        limit = max(record.lookups_used, record.lookups_limit - self._topup_lookups)
        return replace(record, lookups_limit=limit, updated_at=_iso(now))

    def _apply_refund(self, record: EntitlementRecord, *, now: datetime) -> EntitlementRecord:
        """A refund removes the entitlement: the reader is Free again at once."""

        return replace(
            record,
            plan=Plan.FREE,
            lookups_limit=self._free_lookups,
            status=EntitlementStatus.ACTIVE,
            trial_ends_at=None,
            renewing=False,
            updated_at=_iso(now),
        )

    def _apply_lapse(self, record: EntitlementRecord, *, now: datetime) -> EntitlementRecord:
        """A cancellation or failed payment lets the paid period run out.

        The plan stays in force to the period end, reading `grace`; the boundary
        in `_reconciled` then reverts the reader to Free. A lapse on a reader who
        is not on a paid plan changes nothing.
        """

        if record.plan is not Plan.PRO:
            return record
        return replace(
            record,
            renewing=False,
            status=EntitlementStatus.GRACE,
            updated_at=_iso(now),
        )

    async def _record_purchase(
        self, request: EntitlementSyncRequest, *, occurred: datetime, now: datetime
    ) -> None:
        """Record the purchase the event names, and the state it leaves behind."""

        if request.event in (BillingEvent.PURCHASE, BillingEvent.RENEWAL):
            await self._store.record_purchase(
                PurchaseRecord(
                    id=new_purchase_id(),
                    account_id=request.accountId,
                    store=request.store,
                    product_id=request.productId,
                    product_kind=request.productKind,
                    status=PurchaseStatus.ACTIVE,
                    amount_minor=request.amountMinor,
                    currency=request.currency,
                    purchased_at=_iso(occurred),
                )
            )
            return

        if request.event is BillingEvent.REFUND:
            status = PurchaseStatus.REFUNDED
        elif request.event is BillingEvent.FAILED_PAYMENT:
            status = PurchaseStatus.FAILED
        else:
            return
        for purchase in await self._store.purchases_for(
            request.accountId, request.store, request.productId, request.productKind
        ):
            await self._store.save_purchase(
                replace(
                    purchase,
                    status=status,
                    refunded_at=_iso(now) if status is PurchaseStatus.REFUNDED else None,
                )
            )


def _response(record: EntitlementRecord) -> EntitlementResponse:
    return EntitlementResponse(
        plan=record.plan,
        lookupsUsed=record.lookups_used,
        lookupsLimit=record.lookups_limit,
        periodStart=record.period_start,
        periodEnd=record.period_end,
        status=record.status,
        trialEndsAt=record.trial_ends_at,
    )


def _spend_response(record: EntitlementRecord, *, allowed: bool) -> SpendResponse:
    return SpendResponse(
        allowed=allowed,
        plan=record.plan,
        lookupsUsed=record.lookups_used,
        lookupsLimit=record.lookups_limit,
        periodEnd=record.period_end,
    )


def _event_key(request: EntitlementSyncRequest) -> str:
    """The natural key of one billing event, so a redelivery applies once."""

    return "|".join(
        (
            request.accountId,
            request.event.value,
            request.store.value,
            request.productId,
            request.productKind.value,
            request.occurredAt,
        )
    )


def _parse_occurred(value: str) -> datetime:
    try:
        return _parse(value)
    except ValueError as exc:
        raise InvalidRequestError("occurredAt is not a valid timestamp.") from exc


def _parse(value: str) -> datetime:
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat()


def _add_month(moment: datetime) -> datetime:
    """One calendar month on, clamping the day to the target month's length."""

    year = moment.year + (1 if moment.month == 12 else 0)
    month = 1 if moment.month == 12 else moment.month + 1
    day = min(moment.day, calendar.monthrange(year, month)[1])
    return moment.replace(year=year, month=month, day=day)


def _utcnow() -> datetime:
    return datetime.now(UTC)

"""Integration and acceptance tests for the lookup entitlement (FEAT-013).

Verifies the metered account end to end: a signed-in reader's lookup counts
against their entitlement through the account_gateway (C-001), a signed-out reader's
lookup carries no allowance and never meters here, an exhausted allowance
resolves the lookup to the fallback with the word and phrase still shown, and a
stored billing event (C-019) moves the reader between tiers. Account deletion
(C-021) removes the account and its entitlement, and behind it the account_gateway
erases the reader's own data. The meter's own seams — the spend the lookup
service calls and the billing sync the payment processor delivers — are addressed
directly on the account stack, because the account_gateway never exposes them.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import httpx2
import pytest

from tests.conftest import INTERNAL_AUDIENCE

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

INTERNAL = {"x-internal-audience": INTERNAL_AUDIENCE}


def _signed_in(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _anonymous(subject: str) -> dict[str, str]:
    return {"Authorization": f"Bearer dev-anon:{subject}"}


def _subject() -> str:
    return f"ent-{uuid4().hex[:12]}"


def _lookup(
    account_gateway: httpx2.Client,
    subject: str,
    *,
    selection: str | None = None,
    client_id: str | None = None,
    anonymous: bool = False,
) -> httpx2.Response:
    token = _anonymous(subject) if anonymous else _signed_in(subject)
    return account_gateway.post(
        "/v1/lookups",
        headers=token,
        json={
            "selection": selection or f"lorvane-{uuid4().hex[:6]}",
            "clientLookupId": client_id or f"clid-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": True,
        },
    )


def _entitlement(account_gateway: httpx2.Client, subject: str) -> dict[str, Any]:
    response = account_gateway.get("/v1/entitlement", headers=_signed_in(subject))
    assert response.status_code == 200, response.text
    body: dict[str, Any] = response.json()
    return body


def _spend(
    entitlement: httpx2.Client, subject: str, client_id: str | None = None
) -> httpx2.Response:
    """One check-and-spend, the call the lookup service makes before serving."""

    return entitlement.post(
        "/internal/entitlements/spend",
        headers=INTERNAL,
        json={"subject": subject, "clientLookupId": client_id or f"clid-{uuid4().hex}"},
    )


def _sync(entitlement: httpx2.Client, payload: dict[str, Any]) -> httpx2.Response:
    """One signed store billing event, the call the payment processor makes (C-019)."""

    body = {
        "store": "app_store",
        "productId": "com.scenova.pro.monthly",
    }
    body.update(payload)
    return entitlement.post("/internal/entitlements/sync", headers=INTERNAL, json=body)


# --- The meter ---------------------------------------------------------------


def test_a_signed_in_readers_lookup_is_counted(account_gateway: httpx2.Client) -> None:
    # FEAT-013: a signed-in reader's lookup counts against their entitlement. A
    # new account starts on the 7-day Pro trial (monetization.md "Trial
    # Period"), so the meter runs against the trial's allowance.
    subject = _subject()

    before = _entitlement(account_gateway, subject)
    assert before["plan"] == "trial", before
    assert before["lookupsUsed"] == 0, before
    assert before["lookupsLimit"] == 50, before
    assert before["trialEndsAt"], before

    response = _lookup(account_gateway, subject)

    assert response.status_code == 200, response.text
    allowance = response.json()["allowance"]
    assert allowance == {
        "used": 1,
        "limit": 50,
        "periodEnd": before["periodEnd"],
    }, allowance
    assert _entitlement(account_gateway, subject)["lookupsUsed"] == 1


def test_a_hit_and_a_miss_cost_the_reader_the_same(account_gateway: httpx2.Client) -> None:
    # monetization.md "Revenue Model": every lookup spends one unit of allowance
    # whether it is served from the shared library or generated fresh, so the
    # meter is the same on both sides.
    subject = _subject()

    first = _lookup(account_gateway, subject, selection="come").json()
    # "come" is in the sense inventory; the lookup either resolves a stored clip
    # or starts one, and the reader pays the same for both.
    spent_after_hit = _entitlement(account_gateway, subject)["lookupsUsed"]
    assert spent_after_hit == 1, first

    second = _lookup(account_gateway, subject, selection=f"mistrallo-{uuid4().hex[:6]}").json()
    assert _entitlement(account_gateway, subject)["lookupsUsed"] == 2, second


def test_a_resend_of_the_same_lookup_spends_once(account_gateway: httpx2.Client) -> None:
    # C-001 idempotency meets the meter: a client resending the same
    # `clientLookupId` replays the recorded lookup and is metered once, never
    # twice.
    subject = _subject()
    client_id = f"clid-{uuid4().hex}"

    selection = f"lorvane-{uuid4().hex[:6]}"
    first = _lookup(account_gateway, subject, selection=selection, client_id=client_id)
    assert first.status_code == 200, first.text

    replay = _lookup(account_gateway, subject, selection=selection, client_id=client_id)
    assert replay.status_code == 200, replay.text
    assert replay.json()["lookupId"] == first.json()["lookupId"]
    assert _entitlement(account_gateway, subject)["lookupsUsed"] == 1


def test_a_reader_who_is_not_signed_in_is_metered_on_the_device(
    account_gateway: httpx2.Client,
) -> None:
    # FEAT-013: a signed-out reader applies the device-local guest allowance —
    # the client counts their five lookups on the device (monetization.md
    # "Guest Allowance") — and the service never carries an allowance for them:
    # the response carries none and nothing is spent against an account their
    # later sign-in would find.
    subject = _subject()

    response = _lookup(account_gateway, subject, anonymous=True)

    assert response.status_code == 200, response.text
    assert response.json()["allowance"] is None, response.json()
    # Sign-in upgrades the reader's token to their account; the device's guest
    # lookups are not behind the account, so the account they mete into later
    # starts unspent.
    assert _entitlement(account_gateway, subject)["lookupsUsed"] == 0


# --- The spent allowance -----------------------------------------------------


def _drain_allowance(entitlement: httpx2.Client, subject: str, limit: int) -> None:
    """Spend the reader's allowance down through the meter itself.

    The seam is the exact call the lookup service makes (one unit per lookup),
    so filling the month through it fills it the way readers do, only faster.
    """

    for index in range(limit):
        response = _spend(entitlement, subject, client_id=f"clid-{uuid4().hex}")
        assert response.status_code == 200, response.text
        assert response.json()["allowed"] is True, response.text


def test_a_spent_allowance_still_shows_the_word_and_phrase(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # FEAT-013: a reader with no entitlement remaining is told the state and
    # offered a way to add one: the lookup resolves to the fallback with the
    # word and its phrase shown, no clip served or generated, and the allowance
    # answering `used` equal to `limit` — the client's signal to offer more.
    subject = _subject()
    _drain_allowance(account_entitlement, subject, 50)

    response = _lookup(account_gateway, subject, selection="come")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "fallback", body
    assert body["senses"], body
    assert all(sense["glossPhrase"] for sense in body["senses"]), body
    assert all(sense["clip"] is None for sense in body["senses"]), body
    assert body["allowance"]["used"] == 50 == body["allowance"]["limit"], body
    # The refusal is not itself a lookup: nothing further is spent.
    assert _entitlement(account_gateway, subject)["lookupsUsed"] == 50


def test_a_subscription_purchase_restores_the_allowance(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # FEAT-013 / user-flow.md Flow 5 hitting the Paywall mid-read: the reader
    # buys Pro, the entitlement applies at once, and the next lookup is
    # answered rather than refused.
    subject = _subject()
    _drain_allowance(account_entitlement, subject, 50)
    assert _lookup(account_gateway, subject).json()["status"] == "fallback"

    purchase = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "purchase",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )
    assert purchase.status_code == 202, purchase.text
    assert purchase.json() == {"applied": True}

    entitled = _entitlement(account_gateway, subject)
    assert entitled["plan"] == "pro", entitled
    assert entitled["lookupsUsed"] == 0, entitled
    assert entitled["lookupsLimit"] == 50, entitled

    response = _lookup(account_gateway, subject)
    assert response.status_code == 200, response.text
    assert response.json()["status"] != "fallback", response.json()
    assert response.json()["allowance"]["used"] == 1, response.json()


def test_a_topup_adds_to_the_current_period(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # monetization.md "Lookup Top-Up": one pack adds its lookups to the current
    # month, so the spent reader buys back room in the same period.
    subject = _subject()
    # The purchase follows a sign-in: the account exists on the reader's first
    # signed-in sight (C-019 refuses a purchase for an id that names nobody).
    assert _entitlement(account_gateway, subject)["lookupsLimit"] == 50
    _drain_allowance(account_entitlement, subject, 50)

    topup = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "purchase",
            "productKind": "topup",
            "productId": "com.scenova.topup.20",
            "amountMinor": 299,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )
    assert topup.status_code == 202, topup.text
    assert topup.json() == {"applied": True}

    entitled = _entitlement(account_gateway, subject)
    assert entitled["plan"] == "trial", entitled
    assert entitled["lookupsUsed"] == 50, entitled
    assert entitled["lookupsLimit"] == 70, entitled


def test_a_redelivered_billing_event_applies_once(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # C-019: the processor redelivers a webhook until it is acknowledged — the
    # same event is accepted again but changes nothing the second time, so a
    # retry never adds a second pack of lookups.
    subject = _subject()
    assert _entitlement(account_gateway, subject)["lookupsLimit"] == 50
    payload = {
        "accountId": subject,
        "event": "purchase",
        "productKind": "topup",
        "productId": "com.scenova.topup.20",
        "amountMinor": 299,
        "currency": "USD",
        "occurredAt": "2026-10-16T00:00:00Z",
    }

    first = _sync(account_entitlement, payload)
    assert first.status_code == 202, first.text
    assert first.json() == {"applied": True}

    replay = _sync(account_entitlement, payload)

    assert replay.status_code == 202, replay.text
    assert replay.json() == {"applied": False}
    # One pack, not two: the limit rose by 20 lookups only.
    read = account_entitlement.get("/v1/entitlement", headers=_signed_in(subject))
    assert read.json()["lookupsLimit"] == 70, read.text


def test_a_refund_returns_the_reader_to_free(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # monetization.md "Billing Events": the entitlement is removed when a refund
    # is granted — the reader is Free again at once.
    subject = _subject()
    # The subscription follows the sign-up: the account exists on first sight.
    assert _entitlement(account_gateway, subject)["plan"] == "trial"
    purchase = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "purchase",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )
    assert purchase.status_code == 202, purchase.text
    assert (
        account_entitlement.get("/v1/entitlement", headers=_signed_in(subject)).json()["plan"]
        == "pro"
    )

    refund = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "refund",
            "productId": "com.scenova.pro.monthly",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T01:00:00Z",
        },
    )

    assert refund.status_code == 202, refund.text
    assert refund.json() == {"applied": True}
    assert _entitlement(account_gateway, subject)["plan"] == "free"


def test_a_cancellation_lets_the_paid_period_run_out(
    account_gateway: httpx2.Client, account_entitlement: httpx2.Client
) -> None:
    # monetization.md "Billing Events": access continues to the end of the paid
    # period — the plan stays in force for the month it was bought for, reading
    # `grace`, and the meter keeps answering inside it.
    subject = _subject()
    # The subscription follows the sign-up: the account exists on first sight.
    assert _entitlement(account_gateway, subject)["plan"] == "trial"
    purchase = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "purchase",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )
    assert purchase.status_code == 202, purchase.text

    cancellation = _sync(
        account_entitlement,
        {
            "accountId": subject,
            "event": "cancellation",
            "productKind": "subscription",
            "amountMinor": 0,
            "currency": "USD",
            "occurredAt": "2026-10-16T01:00:00Z",
        },
    )

    assert cancellation.status_code == 202, cancellation.text
    entitled = _entitlement(account_gateway, subject)
    assert entitled["plan"] == "pro", entitled
    assert entitled["status"] == "grace", entitled


def test_a_billing_event_for_an_unknown_account_is_refused(
    account_entitlement: httpx2.Client,
) -> None:
    # C-019: 404 when the account the purchase names does not exist.
    response = _sync(
        account_entitlement,
        {
            "accountId": f"nobody-{uuid4().hex[:12]}",
            "event": "purchase",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "account_not_found"


def test_the_meter_and_the_webhook_are_internal_seams(account_entitlement: httpx2.Client) -> None:
    # C-019 / the meter: the payment processor's webhook and the lookup path's
    # spend are never reachable from the reader client — a caller without an
    # internal identity, exactly what a reader's token would present, is
    # refused.
    spend = account_entitlement.post("/internal/entitlements/spend", json={"subject": _subject()})
    sync = account_entitlement.post(
        "/internal/entitlements/sync",
        json={
            "accountId": _subject(),
            "event": "purchase",
            "store": "app_store",
            "productId": "com.scenova.pro.monthly",
            "productKind": "subscription",
            "amountMinor": 699,
            "currency": "USD",
            "occurredAt": "2026-10-16T00:00:00Z",
        },
    )

    assert spend.status_code == 401, spend.text
    assert sync.status_code == 401, sync.text


# --- The account's deletion --------------------------------------------------


def test_deleting_the_account_removes_it_and_its_entitlement(
    account_gateway: httpx2.Client,
) -> None:
    # FEAT-013 / user-flow.md Flow 8: confirming the deletion removes the
    # account and its entitlement; from then on the token's subject has no
    # account, and a repeated deletion is refused the same way.
    subject = _subject()
    assert _lookup(account_gateway, subject).status_code == 200

    deletion = account_gateway.delete("/v1/account", headers=_signed_in(subject))

    assert deletion.status_code == 202, deletion.text
    assert deletion.json() == {"deleted": True}

    assert account_gateway.get("/v1/entitlement", headers=_signed_in(subject)).status_code == 401
    no_account = account_gateway.get("/v1/account", headers=_signed_in(subject))
    assert no_account.status_code == 401, no_account.text
    assert no_account.json()["code"] == "no_account"

    again = account_gateway.delete("/v1/account", headers=_signed_in(subject))
    assert again.status_code == 401, again.text
    assert again.json()["code"] == "no_account"


def test_a_deleted_reader_is_a_new_reader_with_no_account(account_gateway: httpx2.Client) -> None:
    # FEAT-013: after deletion the reader is treated as a new reader — the
    # client signs out and the device-local guest allowance applies, so the
    # service never blocks them and no account is recreated behind the
    # deletion (C-021).
    subject = _subject()
    assert _lookup(account_gateway, subject).status_code == 200
    assert account_gateway.delete("/v1/account", headers=_signed_in(subject)).status_code == 202

    response = _lookup(account_gateway, subject)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["allowance"] is None, body
    # The subject still has no account: a later entitlement read is still the
    # contract's 401, and one is not quietly rebuilt behind the deletion.
    assert account_gateway.get("/v1/entitlement", headers=_signed_in(subject)).status_code == 401


def test_deleting_the_account_erases_the_reader_s_own_data(account_gateway: httpx2.Client) -> None:
    # C-021 behind the account_gateway: the account survives the deletion, but the
    # reader's personal data — the lookups they made — is erased behind it
    # (nfr.md "Data lifecycle"). A lookup that belonged to them before the
    # deletion no longer reads on its id afterwards.
    subject = _subject()
    created = _lookup(account_gateway, subject, client_id="erase-1").json()
    read_before = account_gateway.get(
        f"/v1/lookups/{created['lookupId']}", headers=_signed_in(subject)
    )
    assert read_before.status_code == 200, read_before.text

    deletion = account_gateway.delete("/v1/account", headers=_signed_in(subject))
    assert deletion.status_code == 202, deletion.text

    read_after = account_gateway.get(
        f"/v1/lookups/{created['lookupId']}", headers=_signed_in(subject)
    )
    assert read_after.status_code == 404, read_after.text

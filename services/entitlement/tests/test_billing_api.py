"""API tests for the store billing webhook (C-019).

A subscription sets the plan and the allowance period, a top-up adds its lookups
to the current period and does not carry over, a refund removes the entitlement,
and a cancellation or a failed payment lets the paid period run out before the
reader reverts to free (monetization.md "Billing Events").
"""

from __future__ import annotations

import httpx2
from fastapi.testclient import TestClient

from entitlement.tests.fakes import (
    INTERNAL,
    WEBHOOK,
    make_client,
    provision,
    rig,
    sync_body,
)


def _sync(client: TestClient, **overrides: object) -> httpx2.Response:
    return client.post("/internal/entitlements/sync", headers=INTERNAL, json=sync_body(**overrides))


def test_a_subscription_sets_the_plan_and_the_allowance_period() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        before = provision(client)
        response = _sync(client)
        after = provision(client)

    assert response.status_code == 202
    assert response.json() == {"applied": True}
    assert before["plan"] == "trial"
    assert after["plan"] == "pro"
    assert after["lookupsLimit"] == 50
    assert after["lookupsUsed"] == 0
    assert after["status"] == "active"
    assert after["trialEndsAt"] is None


def test_a_top_up_adds_lookups_to_the_current_period() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client, productKind="topup", productId="scenova.topup.20", amountMinor=299)
        after = provision(client)

    assert after["lookupsLimit"] == 70
    assert after["plan"] == "trial"


def test_a_top_up_does_not_carry_into_the_next_period() -> None:
    # monetization.md "Lookup Top-Up": the extra lookups are used before the next
    # reset and are not carried over.
    rigged = rig(trial_days=0)
    with make_client(rigged) as client:
        provision(client)
        _sync(client, productKind="topup", productId="scenova.topup.20", amountMinor=299)
        bought = provision(client)
        rigged.clock.advance(days=32)
        after = provision(client)

    assert bought["lookupsLimit"] == 40
    assert after["lookupsLimit"] == 20
    assert after["lookupsUsed"] == 0


def test_a_renewal_resets_the_period_and_the_used_count() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client)
        client.post(
            "/internal/entitlements/spend",
            headers=INTERNAL,
            json={"subject": "reader-1", "clientLookupId": "lk_1"},
        )
        rigged.clock.advance(days=31)
        _sync(client, event="renewal", occurredAt="2026-11-15T12:00:00+00:00")
        after = provision(client)

    assert after["plan"] == "pro"
    assert after["lookupsUsed"] == 0
    assert after["lookupsLimit"] == 50


def test_a_cancellation_lets_the_paid_period_run_out() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client)
        _sync(client, event="cancellation")
        during = provision(client)
        rigged.clock.advance(days=31)
        after = provision(client)

    assert during["plan"] == "pro"
    assert during["status"] == "grace"
    assert after["plan"] == "free"
    assert after["lookupsLimit"] == 20
    assert after["status"] == "expired"


def test_a_failed_payment_reads_as_grace() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client)
        _sync(client, event="failed_payment")
        after = provision(client)

    assert after["plan"] == "pro"
    assert after["status"] == "grace"


def test_a_refund_removes_the_entitlement_at_once() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client)
        _sync(client, event="refund")
        after = provision(client)

    assert after["plan"] == "free"
    assert after["lookupsLimit"] == 20
    assert after["status"] == "active"


def test_a_refunded_top_up_takes_its_lookups_back() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _sync(client, productKind="topup", productId="scenova.topup.20", amountMinor=299)
        _sync(client, event="refund", productKind="topup", productId="scenova.topup.20")
        after = provision(client)

    assert after["lookupsLimit"] == 50


def test_a_redelivered_event_applies_once() -> None:
    # The processor retries a webhook until it is acknowledged, so a second
    # delivery must not add a second top-up.
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        first = _sync(client, productKind="topup", productId="scenova.topup.20", amountMinor=299)
        second = _sync(client, productKind="topup", productId="scenova.topup.20", amountMinor=299)
        after = provision(client)

    assert first.json() == {"applied": True}
    assert second.json() == {"applied": False}
    assert after["lookupsLimit"] == 70


def test_an_unknown_account_is_not_found() -> None:
    with make_client(rig()) as client:
        response = _sync(client, accountId="nobody")

    assert response.status_code == 404
    assert response.json()["code"] == "account_not_found"


def test_an_unknown_event_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        response = _sync(client, event="chargeback")

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_product_kind_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        response = _sync(client, productKind="lifetime")

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_missing_amount_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        body = sync_body()
        body.pop("amountMinor")
        response = client.post("/internal/entitlements/sync", headers=INTERNAL, json=body)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_renewal_of_a_top_up_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        response = _sync(client, event="renewal", productKind="topup")

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_the_webhook_requires_the_processor_or_an_internal_identity() -> None:
    with make_client(rig()) as client:
        provision(client)
        missing = client.post("/internal/entitlements/sync", json=sync_body())
        wrong = client.post(
            "/internal/entitlements/sync",
            headers={"Authorization": "Bearer not-the-secret"},
            json=sync_body(),
        )

    assert missing.status_code == 401
    assert wrong.status_code == 401
    assert missing.json()["code"] == "unauthorized"


def test_the_processor_webhook_secret_is_accepted() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        response = client.post("/internal/entitlements/sync", headers=WEBHOOK, json=sync_body())
        after = provision(client)

    assert response.status_code == 202
    assert after["plan"] == "pro"


def test_a_cancellation_from_a_non_paying_reader_changes_nothing() -> None:
    # A reader on the free allowance has no paid period to lapse, so the event is
    # accepted without an effect and reports itself as not applied.
    rigged = rig(trial_days=0)
    with make_client(rigged) as client:
        provision(client)
        response = _sync(client, event="cancellation")
        after = provision(client)

    assert response.json() == {"applied": False}
    assert after["plan"] == "free"

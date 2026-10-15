"""API and service tests for account deletion (C-021).

A signed-in reader's deletion removes the account and its entitlement, and from
then on the token's subject has no account: no plan, no allowance, and nothing to
meter a lookup against. The shared library is untouched, and a store subscription
is not cancelled by the product — the reader cancels it in the store.
"""

from __future__ import annotations

import asyncio

from entitlement.app.models import ProductKind, StoreName
from entitlement.tests.fakes import (
    ANONYMOUS,
    INTERNAL,
    READER,
    SUBJECT,
    make_client,
    provision,
    rig,
    sync_body,
)


def test_a_signed_in_reader_deletes_their_account() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        response = client.delete("/v1/account", headers=READER)
        afterwards = client.get("/v1/entitlement", headers=READER)

    assert response.status_code == 202
    assert response.json() == {"deleted": True}
    # The account and its entitlement are gone, so the token subject has no
    # account and the reader is returned to the signed-out state (C-021).
    assert afterwards.status_code == 401
    assert afterwards.json()["code"] == "no_account"


def test_deletion_removes_the_entitlement_and_marks_the_account() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        assert asyncio.run(rigged.store.entitlement(SUBJECT)) is not None
        client.delete("/v1/account", headers=READER)

    account = asyncio.run(rigged.store.account(SUBJECT))
    assert account is not None
    assert account.deleted_at is not None
    assert asyncio.run(rigged.store.entitlement(SUBJECT)) is None


def test_a_deleted_account_is_never_recreated() -> None:
    # Reading the entitlement creates an account on first sight; a deleted one is
    # a tombstone, so the read is refused rather than minting a fresh trial.
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        client.delete("/v1/account", headers=READER)
        client.get("/v1/entitlement", headers=READER)

    account = asyncio.run(rigged.store.account(SUBJECT))
    assert account is not None
    assert account.deleted_at is not None
    assert asyncio.run(rigged.store.entitlement(SUBJECT)) is None


def test_a_deleted_account_cannot_spend_a_lookup() -> None:
    # No allowance is left to meter against, so the lookup path's check-and-spend
    # refuses and the lookup resolves to the fallback without a clip.
    with make_client(rig()) as client:
        provision(client)
        client.delete("/v1/account", headers=READER)
        response = client.post(
            "/internal/entitlements/spend",
            headers=INTERNAL,
            json={"subject": SUBJECT, "clientLookupId": "lk_1"},
        )

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_deleting_twice_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        first = client.delete("/v1/account", headers=READER)
        second = client.delete("/v1/account", headers=READER)

    assert first.status_code == 202
    assert second.status_code == 401
    assert second.json()["code"] == "no_account"


def test_a_token_with_no_account_cannot_delete() -> None:
    # A valid signed-in token the service has never seen has no account; deletion
    # never creates one to delete (C-021).
    rigged = rig()
    with make_client(rigged) as client:
        response = client.delete("/v1/account", headers=READER)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"
    assert asyncio.run(rigged.store.account(SUBJECT)) is None


def test_an_anonymous_token_cannot_delete() -> None:
    with make_client(rig()) as client:
        response = client.delete("/v1/account", headers=ANONYMOUS)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_deletion_requires_a_token() -> None:
    with make_client(rig()) as client:
        missing = client.delete("/v1/account")
        invalid = client.delete("/v1/account", headers={"Authorization": "Bearer nope"})

    assert missing.status_code == 401
    assert missing.json()["code"] == "unauthorized"
    assert invalid.status_code == 401
    assert invalid.json()["code"] == "unauthorized"


def test_deletion_does_not_cancel_a_store_subscription() -> None:
    # The product does not cancel the store subscription, and the purchase stays
    # on file as a financial record (nfr.md "Data lifecycle"); the reader is told
    # in the dialog to cancel it in the store (C-021).
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        client.post("/internal/entitlements/sync", headers=INTERNAL, json=sync_body())
        response = client.delete("/v1/account", headers=READER)

    purchases = asyncio.run(
        rigged.store.purchases_for(
            SUBJECT, StoreName.APP_STORE, "scenova.pro.monthly", ProductKind.SUBSCRIPTION
        )
    )
    assert response.status_code == 202
    assert len(purchases) == 1
    assert purchases[0].product_id == "scenova.pro.monthly"

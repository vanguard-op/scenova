"""Tests for the account retention purge (FEAT-013; nfr.md "Data lifecycle").

A deleted account is a tombstone until the documented window closes: the reader is
signed out and no lookup meters against it, but the record still holds their
personal data. The retention pass hard-deletes the record once the window has
passed, so the deletion request is honoured within 30 days. The financial records
and the shared library are left as they are.
"""

from __future__ import annotations

import asyncio

from fastapi.testclient import TestClient

from entitlement.app.models import ProductKind, StoreName
from entitlement.tests.fakes import (
    INTERNAL,
    READER,
    SUBJECT,
    make_client,
    provision,
    rig,
    sync_body,
)

# A second reader, so a pass over two deleted accounts can show the window
# selecting between them.
_READER_2 = {"Authorization": "Bearer dev:reader-2"}
_SUBJECT_2 = "reader-2"


def _delete(client: TestClient, headers: dict[str, str] = READER) -> None:
    response = client.delete("/v1/account", headers=headers)
    assert response.status_code == 202, response.text


def _purge(client: TestClient) -> dict[str, object]:
    response = client.post("/internal/accounts/purge", headers=INTERNAL)
    assert response.status_code == 200, response.text
    return response.json()  # type: ignore[no-any-return]


def test_a_deleted_account_past_the_window_is_hard_deleted() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=31)
        result = _purge(client)

    assert result == {"purged": 1}
    # The record and its personal data are gone, not merely marked.
    assert asyncio.run(rigged.store.account(SUBJECT)) is None


def test_a_deleted_account_within_the_window_is_kept() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=29)
        result = _purge(client)

    assert result == {"purged": 0}
    account = asyncio.run(rigged.store.account(SUBJECT))
    assert account is not None
    assert account.deleted_at is not None


def test_the_window_closes_on_the_thirtieth_day() -> None:
    # "Hard-delete within 30 days of request" (nfr.md "Data lifecycle"): the
    # thirtieth day is inside the window, so the record goes.
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=30)
        result = _purge(client)

    assert result == {"purged": 1}
    assert asyncio.run(rigged.store.account(SUBJECT)) is None


def test_only_the_accounts_past_the_window_go() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=5)
        provision(client, headers=_READER_2)
        _delete(client, headers=_READER_2)
        rigged.clock.advance(days=26)
        result = _purge(client)

    assert result == {"purged": 1}
    assert asyncio.run(rigged.store.account(SUBJECT)) is None
    kept = asyncio.run(rigged.store.account(_SUBJECT_2))
    assert kept is not None
    assert kept.deleted_at is not None


def test_a_live_account_is_never_purged() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        rigged.clock.advance(days=90)
        result = _purge(client)

    assert result == {"purged": 0}
    account = asyncio.run(rigged.store.account(SUBJECT))
    assert account is not None
    assert account.deleted_at is None


def test_the_pass_is_idempotent() -> None:
    # It is a scheduled job: a second run finds nothing due and reports zero.
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=31)
        first = _purge(client)
        second = _purge(client)

    assert first == {"purged": 1}
    assert second == {"purged": 0}


def test_the_purge_leaves_no_entitlement_behind() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _delete(client)
        rigged.clock.advance(days=31)
        _purge(client)

    assert asyncio.run(rigged.store.entitlement(SUBJECT)) is None


def test_the_purge_keeps_the_financial_record() -> None:
    # nfr.md "Data lifecycle": financial records are kept for seven years, so the
    # account's personal data goes while the purchase stays on file.
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        client.post("/internal/entitlements/sync", headers=INTERNAL, json=sync_body())
        _delete(client)
        rigged.clock.advance(days=31)
        _purge(client)

    purchases = asyncio.run(
        rigged.store.purchases_for(
            SUBJECT, StoreName.APP_STORE, "scenova.pro.monthly", ProductKind.SUBSCRIPTION
        )
    )
    assert len(purchases) == 1


def test_the_purge_seam_requires_an_internal_identity() -> None:
    with make_client(rig()) as client:
        response = client.post("/internal/accounts/purge")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"

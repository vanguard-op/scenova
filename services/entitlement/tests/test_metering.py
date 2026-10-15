"""Tests for the lookup path's check-and-spend (FEAT-013).

One lookup spends one unit of the allowance whether it is served or generated; a
lookup with nothing left is refused without spending, so it resolves to the
fallback with `used` equal to `limit` (C-001).
"""

from __future__ import annotations

import httpx2
from fastapi.testclient import TestClient

from entitlement.tests.fakes import INTERNAL, make_client, provision, rig


def _spend(
    client: TestClient, *, subject: str = "reader-1", client_lookup_id: str | None = "lk_1"
) -> httpx2.Response:
    body: dict[str, object] = {"subject": subject}
    if client_lookup_id is not None:
        body["clientLookupId"] = client_lookup_id
    return client.post("/internal/entitlements/spend", headers=INTERNAL, json=body)


def test_a_lookup_spends_one_unit() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        response = _spend(client)
        after = provision(client)

    assert response.status_code == 200
    body = response.json()
    assert body["allowed"] is True
    assert body["lookupsUsed"] == 1
    assert body["lookupsLimit"] == 50
    assert after["lookupsUsed"] == 1


def test_a_spent_allowance_refuses_the_lookup_without_spending() -> None:
    rigged = rig(free_lookups=2, trial_days=0)
    with make_client(rigged) as client:
        provision(client)
        _spend(client, client_lookup_id="lk_1")
        _spend(client, client_lookup_id="lk_2")
        exhausted = _spend(client, client_lookup_id="lk_3")
        after = provision(client)

    assert exhausted.json()["allowed"] is False
    assert exhausted.json()["lookupsUsed"] == 2
    assert exhausted.json()["lookupsLimit"] == 2
    assert after["lookupsUsed"] == 2


def test_a_resent_lookup_spends_once() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        _spend(client, client_lookup_id="lk_1")
        replay = _spend(client, client_lookup_id="lk_1")
        after = provision(client)

    assert replay.json()["allowed"] is True
    assert replay.json()["lookupsUsed"] == 1
    assert after["lookupsUsed"] == 1


def test_the_spend_seam_requires_an_internal_identity() -> None:
    with make_client(rig()) as client:
        response = client.post(
            "/internal/entitlements/spend", json={"subject": "reader-1", "clientLookupId": "lk_1"}
        )

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"

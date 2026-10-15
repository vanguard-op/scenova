"""Tests for the paid-tier kill switch (FEAT-013).

release.md "Rollout Phases & Feature Flags": the `enable_paid_tier` flag is off
until the paid tier rolls out, and its kill switch reverts every reader to Free
and hides the Paywall. The service applies it when a reader is served or metered,
so an exhausted allowance shows the word and phrase with no plan to buy while the
stored plan is held for when the tier returns.
"""

from __future__ import annotations

import httpx2
from fastapi.testclient import TestClient

from entitlement.app.config import Settings
from entitlement.app.store import InMemoryEntitlementStore
from entitlement.tests.fakes import INTERNAL, make_client, provision, rig, sync_body


def _spend(
    client: TestClient, *, subject: str = "reader-1", client_lookup_id: str | None = "lk_1"
) -> httpx2.Response:
    body: dict[str, object] = {"subject": subject}
    if client_lookup_id is not None:
        body["clientLookupId"] = client_lookup_id
    return client.post("/internal/entitlements/spend", headers=INTERNAL, json=body)


def test_the_flag_defaults_on_and_is_read_from_the_environment() -> None:
    # The code default is the rolled-out state, so a missing variable never
    # silently reverts a reader who has paid; every environment supplies its
    # rollout value.
    assert Settings.from_env({}).enable_paid_tier is True
    assert Settings.from_env({"FLAG_ENABLE_PAID_TIER": "false"}).enable_paid_tier is False
    assert Settings.from_env({"FLAG_ENABLE_PAID_TIER": "true"}).enable_paid_tier is True


def test_the_kill_switch_serves_a_signed_in_reader_as_free() -> None:
    rigged = rig(paid_tier_enabled=False)
    with make_client(rigged) as client:
        body = provision(client)

    assert body["plan"] == "free"
    assert body["lookupsUsed"] == 0
    assert body["lookupsLimit"] == 20
    assert body["status"] == "active"
    assert body["trialEndsAt"] is None


def test_the_kill_switch_meters_on_the_free_allowance() -> None:
    rigged = rig(free_lookups=2, trial_days=0, paid_tier_enabled=False)
    with make_client(rigged) as client:
        provision(client)
        first = _spend(client, client_lookup_id="lk_1")
        _spend(client, client_lookup_id="lk_2")
        exhausted = _spend(client, client_lookup_id="lk_3")
        after = provision(client)

    assert first.json()["plan"] == "free"
    assert first.json()["lookupsLimit"] == 2
    assert exhausted.json()["allowed"] is False
    assert exhausted.json()["lookupsUsed"] == 2
    assert exhausted.json()["lookupsLimit"] == 2
    assert after["lookupsLimit"] == 2


def test_a_paid_subscription_is_served_and_metered_as_free_while_the_tier_is_off() -> None:
    # A store purchase still reaches the account, but the reader is served as
    # Free until the tier returns.
    rigged = rig(free_lookups=2, pro_lookups=50, trial_days=0, paid_tier_enabled=False)
    with make_client(rigged) as client:
        provision(client)
        applied = client.post("/internal/entitlements/sync", headers=INTERNAL, json=sync_body())
        body = provision(client)
        _spend(client, client_lookup_id="lk_1")
        _spend(client, client_lookup_id="lk_2")
        exhausted = _spend(client, client_lookup_id="lk_3")

    assert applied.json() == {"applied": True}
    assert body["plan"] == "free"
    assert body["lookupsLimit"] == 2
    assert exhausted.json()["allowed"] is False
    assert exhausted.json()["lookupsUsed"] == 2


def test_re_enabling_the_tier_restores_the_stored_plan() -> None:
    # The kill switch is a serve-time view, not a write: the reader's trial is
    # held while the tier is off and served again when it returns, so no reader
    # is made to buy their plan twice.
    store = InMemoryEntitlementStore()
    off = rig(trial_days=7, paid_tier_enabled=False, store=store)
    with make_client(off) as client:
        while_off = provision(client)
    on = rig(trial_days=7, paid_tier_enabled=True, store=store, clock=off.clock)
    with make_client(on) as client:
        while_on = provision(client)

    assert while_off["plan"] == "free"
    assert while_off["trialEndsAt"] is None
    assert while_on["plan"] == "trial"
    assert while_on["lookupsLimit"] == 50
    assert while_on["trialEndsAt"] is not None

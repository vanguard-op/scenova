"""API tests for the entitlement read and the account update (C-018, C-020).

A signed-in reader's entitlement follows their account; an anonymous token has no
account and is refused. The account holds the consent choice and the locale, so
both travel with the reader to a new device.
"""

from __future__ import annotations

from entitlement.tests.fakes import (
    ANONYMOUS,
    READER,
    make_client,
    provision,
    rig,
)


def test_healthz() -> None:
    with make_client(rig()) as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "entitlement"}


def test_a_signed_in_reader_starts_on_the_pro_trial() -> None:
    # monetization.md "Trial Period": the 7-day Pro trial is at sign-up, and it
    # carries the Pro allowance for its length.
    with make_client(rig()) as client:
        body = provision(client)

    assert body["plan"] == "trial"
    assert body["lookupsUsed"] == 0
    assert body["lookupsLimit"] == 50
    assert body["status"] == "active"
    assert body["trialEndsAt"] is not None
    assert body["periodStart"] < body["periodEnd"]


def test_the_trial_ends_into_the_free_allowance() -> None:
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        rigged.clock.advance(days=8)
        body = provision(client)

    assert body["plan"] == "free"
    assert body["lookupsLimit"] == 20
    assert body["trialEndsAt"] is None
    assert body["status"] == "active"


def test_the_entitlement_follows_the_account_to_a_new_device() -> None:
    # The same signed-in subject on a second client is the same account, so the
    # reader's used count and consent come with them (FEAT-013).
    rigged = rig()
    with make_client(rigged) as client:
        provision(client)
        client.patch("/v1/account", headers=READER, json={"consentModelProcessing": True})
        client.post(
            "/internal/entitlements/spend",
            headers={"x-internal-audience": "scenova-internal"},
            json={"subject": "reader-1", "clientLookupId": "lk_1"},
        )
    with make_client(rigged) as other_device:
        body = provision(other_device)
        account = other_device.patch(
            "/v1/account", headers=READER, json={"consentModelProcessing": True}
        )

    assert body["lookupsUsed"] == 1
    assert account.json()["consentModelProcessing"] is True


def test_an_anonymous_token_has_no_account() -> None:
    with make_client(rig()) as client:
        response = client.get("/v1/entitlement", headers=ANONYMOUS)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_a_missing_token_is_unauthorized() -> None:
    with make_client(rig()) as client:
        response = client.get("/v1/entitlement")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_invalid_token_is_unauthorized() -> None:
    with make_client(rig()) as client:
        response = client.get("/v1/entitlement", headers={"Authorization": "Bearer nope"})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_the_account_update_stores_consent_and_locale() -> None:
    with make_client(rig()) as client:
        provision(client)
        response = client.patch(
            "/v1/account",
            headers=READER,
            json={"consentModelProcessing": True, "locale": "en-gb"},
        )
        read_back = client.patch("/v1/account", headers=READER, json={"locale": "en-gb"})

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": True, "locale": "en-GB"}
    assert read_back.json() == {"consentModelProcessing": True, "locale": "en-GB"}


def test_an_account_update_with_no_field_is_refused() -> None:
    with make_client(rig()) as client:
        provision(client)
        response = client.patch("/v1/account", headers=READER, json={})

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_locale_is_refused() -> None:
    # Preferences lets a reader choose any language the product can name, even
    # one with no translation yet (FEAT-012); a value that is not a language is
    # the contract's unknown locale.
    with make_client(rig()) as client:
        provision(client)
        response = client.patch("/v1/account", headers=READER, json={"locale": "zz"})

    assert response.status_code == 400
    assert response.json()["code"] == "unknown_locale"


def test_the_account_update_requires_a_token() -> None:
    with make_client(rig()) as client:
        response = client.patch("/v1/account", json={"consentModelProcessing": True})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_the_account_update_refuses_an_anonymous_token() -> None:
    with make_client(rig()) as client:
        response = client.patch(
            "/v1/account", headers=ANONYMOUS, json={"consentModelProcessing": True}
        )

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"

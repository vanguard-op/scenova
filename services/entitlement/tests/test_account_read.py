"""API tests for the account settings read (C-022).

A signed-in reader's consent choice and action-label language live on their
account, so a choice made on one device reads back on another; a reader who is
not signed in holds both on the device and is refused here (FEAT-012).
"""

from __future__ import annotations

from entitlement.tests.fakes import (
    ANONYMOUS,
    READER,
    make_client,
    provision,
    rig,
)


def test_a_signed_in_reader_reads_back_their_account_settings() -> None:
    with make_client(rig()) as client:
        provision(client)
        written = client.patch(
            "/v1/account",
            headers=READER,
            json={"consentModelProcessing": True, "locale": "en-gb"},
        )
        read_back = client.get("/v1/account", headers=READER)

    assert written.status_code == 200
    assert read_back.status_code == 200
    assert read_back.json() == {"consentModelProcessing": True, "locale": "en-GB"}


def test_the_settings_follow_the_reader_to_a_new_device() -> None:
    # The account is keyed by the reader's identity subject, which is the same
    # on their second device, so the new device reads the stored choice
    # (FEAT-012).
    rigged = rig()
    with make_client(rigged) as first_device:
        provision(first_device)
        first_device.patch(
            "/v1/account",
            headers=READER,
            json={"consentModelProcessing": True, "locale": "fr"},
        )
    with make_client(rigged) as new_device:
        response = new_device.get("/v1/account", headers=READER)

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": True, "locale": "fr"}


def test_a_new_account_reads_the_defaults() -> None:
    # An account is created the first time a signed-in reader is seen, with
    # consent off and the launch locale; the read finds those defaults rather
    # than refusing a reader who has not chosen yet.
    with make_client(rig()) as client:
        response = client.get("/v1/account", headers=READER)

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": False, "locale": "en"}


def test_a_withdrawn_consent_reads_back() -> None:
    # The stored choice is the latest one, so a consent given and then taken
    # away reads as declined (FEAT-012).
    with make_client(rig()) as client:
        provision(client)
        client.patch("/v1/account", headers=READER, json={"consentModelProcessing": True})
        client.patch("/v1/account", headers=READER, json={"consentModelProcessing": False})
        response = client.get("/v1/account", headers=READER)

    assert response.json()["consentModelProcessing"] is False


def test_an_anonymous_token_has_no_account() -> None:
    # Signed out, the choice is held on the device alone and the reader never
    # reaches this read (C-022).
    with make_client(rig()) as client:
        response = client.get("/v1/account", headers=ANONYMOUS)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_a_deleted_account_has_no_account() -> None:
    with make_client(rig()) as client:
        provision(client)
        client.delete("/v1/account", headers=READER)
        response = client.get("/v1/account", headers=READER)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_the_account_read_requires_a_token() -> None:
    with make_client(rig()) as client:
        missing = client.get("/v1/account")
        invalid = client.get("/v1/account", headers={"Authorization": "Bearer nope"})

    assert missing.status_code == 401
    assert missing.json()["code"] == "unauthorized"
    assert invalid.status_code == 401
    assert invalid.json()["code"] == "unauthorized"

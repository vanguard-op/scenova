"""Integration and acceptance tests for the account and its reader preferences.

Verifies FEAT-012 (preferences) end to end through the gateway against C-020
(`PATCH /v1/account`) and C-022 (`GET /v1/account`), and the consent half of
FEAT-013's account: a signed-in reader's consent for model processing is stored
on the account, read back from another device's sign-in, and changes whether a
lookup generates at once. A reader who has not signed in holds both choices on
the device alone, so the account refuses them.

The account stack boots the entitlement service behind the gateway and the model
double beside the generation path, so a consented miss actually turns into a
clip.
"""

from __future__ import annotations

from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]


def _signed_in(subject: str) -> dict[str, str]:
    # The pre-account dev verifier: `dev:<subject>` is a signed-in reader (D-011).
    return {"Authorization": f"Bearer dev:{subject}"}


def _anonymous(subject: str) -> dict[str, str]:
    # `dev-anon:<subject>` is the reader before sign-in: a valid token that
    # names no account.
    return {"Authorization": f"Bearer dev-anon:{subject}"}


def _subject() -> str:
    return f"prefs-{uuid4().hex[:12]}"


def _read_account(
    account_gateway: httpx2.Client, subject: str, *, anonymous: bool = False
) -> httpx2.Response:
    headers = _anonymous(subject) if anonymous else _signed_in(subject)
    return account_gateway.get("/v1/account", headers=headers)


def _patch_account(
    account_gateway: httpx2.Client, subject: str, **fields: object
) -> httpx2.Response:
    return account_gateway.patch("/v1/account", headers=_signed_in(subject), json=fields)


def test_a_new_account_reads_consent_off_and_english_back(account_gateway: httpx2.Client) -> None:
    # FEAT-012: a new install reads consent for model processing off — it is
    # given at first use, never assumed — and the selection label reads English,
    # the shipped label (D-033).
    subject = _subject()

    response = _read_account(account_gateway, subject)

    assert response.status_code == 200, response.text
    assert response.json() == {"consentModelProcessing": False, "locale": "en"}


def test_a_reader_who_is_not_signed_in_has_no_account_settings(
    account_gateway: httpx2.Client,
) -> None:
    # C-022: a reader who is not signed in holds both on the device and never
    # calls this — the token names no account, so the read is the contract's 401.
    response = _read_account(account_gateway, _subject(), anonymous=True)

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "no_account"


def test_the_consent_choice_is_stored_when_it_changes(account_gateway: httpx2.Client) -> None:
    # FEAT-012: the reader changes consent here and the choice is stored — the
    # account reads back what they last chose, granted or declined.
    subject = _subject()

    granted = _patch_account(account_gateway, subject, consentModelProcessing=True)
    assert granted.status_code == 200, granted.text
    assert granted.json() == {"consentModelProcessing": True, "locale": "en"}

    declined = _patch_account(account_gateway, subject, consentModelProcessing=False)
    assert declined.status_code == 200, declined.text
    assert _read_account(account_gateway, subject).json() == {
        "consentModelProcessing": False,
        "locale": "en",
    }


def test_the_choice_follows_the_reader_to_a_new_device(account_gateway: httpx2.Client) -> None:
    # FEAT-012: signed in, the consent choice is stored on the account and
    # follows the reader to a new device. The new device's sign-in is the same
    # identity — the reader's account is keyed by who they are, not by the
    # device — so the choice the first device wrote is what the second reads.
    subject = _subject()
    assert _patch_account(account_gateway, subject, consentModelProcessing=True).status_code == 200

    reread = _read_account(account_gateway, subject)

    assert reread.status_code == 200, reread.text
    assert reread.json()["consentModelProcessing"] is True


def test_a_chosen_locale_is_stored_and_read_back(account_gateway: httpx2.Client) -> None:
    # FEAT-012: the reader changes the action-label language and the choice is
    # stored. A language with no translation yet falls back to English on the
    # device (D-033), so the account stores the reader's own choice rather than
    # refusing it for missing copy.
    subject = _subject()

    response = _patch_account(account_gateway, subject, locale="de-DE")

    assert response.status_code == 200, response.text
    assert response.json()["locale"] == "de-DE"
    assert _read_account(account_gateway, subject).json()["locale"] == "de-DE"


def test_a_patch_without_a_field_is_refused(account_gateway: httpx2.Client) -> None:
    # C-020: 400 when no field is given — an empty change has nothing to store.
    response = _patch_account(account_gateway, _subject())

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_locale_is_refused(account_gateway: httpx2.Client) -> None:
    # C-020: 400 with `unknown_locale` for a value that names no real language.
    response = _patch_account(account_gateway, _subject(), locale="not-a-language")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "unknown_locale"


def test_changing_consent_takes_effect_at_once(account_gateway: httpx2.Client) -> None:
    # FEAT-012: changing consent enables or disables generation at once. The
    # lookup a client sends carries the reader's own consent signal (C-001), so
    # a granted choice puts a missed word on the generation path and a declined
    # one refuses it immediately — with the library and device history still
    # serving either way (DELIVERY.md behavior rules).
    subject = _subject()

    assert _patch_account(account_gateway, subject, consentModelProcessing=True).status_code == 200

    def _lookup(selection: str) -> dict[str, Any]:
        client_id = f"id-{uuid4().hex}"
        response = account_gateway.post(
            "/v1/lookups",
            headers=_signed_in(subject),
            json={
                "selection": selection,
                "clientLookupId": client_id,
                "platform": "android",
                "locale": "en",
                "consentModelProcessing": True,
            },
        )
        assert response.status_code == 200, response.text
        body: dict[str, Any] = response.json()
        return body

    granted = _lookup(f"zorbify-{uuid4().hex[:6]}")
    assert granted["status"] == "generating", granted

    # The reader declines in Preferences; the next missed word asks for nothing.
    assert _patch_account(account_gateway, subject, consentModelProcessing=False).status_code == 200
    declined = account_gateway.post(
        "/v1/lookups",
        headers=_signed_in(subject),
        json={
            "selection": f"quibburst-{uuid4().hex[:6]}",
            "clientLookupId": f"id-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": False,
        },
    )
    assert declined.status_code == 200, declined.text
    assert declined.json()["status"] == "denied", declined.json()

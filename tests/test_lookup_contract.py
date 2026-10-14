"""Integration and acceptance tests for the client lookup contracts.

Verifies FEAT-003 (word normalisation and sense selection) end to end through the
gateway, against C-001 (`POST /v1/lookups`) and C-002 (`GET /v1/lookups/{id}`).
The gateway is exercised as it ships: it authenticates, rate-limits, and passes
the lookup service's response through unchanged, so these tests also prove the
two services agree on the frozen contract.
"""

from __future__ import annotations

from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

RESPONSE_KEYS = {
    "lookupId",
    "kind",
    "rawSelection",
    "normalisedLemma",
    "status",
    "senses",
    "notice",
    "correlationId",
}

BEST_GUESS_FRAGMENT = "best guess"


def _auth(subject: str = "reader-1") -> dict[str, str]:
    # The pre-account dev verifier accepts `dev:<subject>` (D-011).
    return {"Authorization": f"Bearer dev:{subject}"}


def _create(
    gateway: httpx2.Client,
    selection: str,
    *,
    client_id: str | None = None,
    subject: str = "reader-1",
    consent: bool = True,
    platform: str = "android",
    locale: str = "en",
) -> httpx2.Response:
    return gateway.post(
        "/v1/lookups",
        headers=_auth(subject),
        json={
            "selection": selection,
            "clientLookupId": client_id or f"id-{uuid4().hex}",
            "platform": platform,
            "locale": locale,
            "consentModelProcessing": consent,
        },
    )


def test_create_lookup_returns_the_frozen_shape(gateway: httpx2.Client) -> None:
    response = _create(gateway, "coming")

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == RESPONSE_KEYS
    assert body["kind"] == "word"
    assert body["rawSelection"] == "coming"
    assert body["correlationId"]
    # The correlation id is echoed on the response header as well as the body.
    assert response.headers.get("x-correlation-id") == body["correlationId"]


@pytest.mark.parametrize("selection", ["coming", "came", "comes"])
def test_inflections_share_one_base_form(gateway: httpx2.Client, selection: str) -> None:
    # FEAT-003: any form of a word resolves to the same base form as the key.
    response = _create(gateway, selection, client_id=f"id-{selection}")

    assert response.status_code == 200, response.text
    assert response.json()["normalisedLemma"] == "come"


def test_education_shares_the_educate_stem(gateway: httpx2.Client) -> None:
    # FEAT-003: "educate" and "education" share a stem.
    response = _create(gateway, "education")

    assert response.status_code == 200, response.text
    assert response.json()["normalisedLemma"] == "educate"


def test_a_word_with_several_common_senses_returns_more_than_one(gateway: httpx2.Client) -> None:
    # FEAT-003: a word with more than one common sense can carry more than one
    # sense (one clip per sense, once the shared library serves clips).
    response = _create(gateway, "bank")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["normalisedLemma"] == "bank"
    assert len(body["senses"]) >= 2
    labels = [sense["senseLabel"] for sense in body["senses"]]
    assert len(set(labels)) == len(labels)


def test_an_unknown_word_is_the_key_and_flagged_as_a_best_guess(
    gateway: httpx2.Client,
) -> None:
    # FEAT-003: a word absent from the sense inventory keeps the word as the key
    # and the reader is told the sense is a best guess (the advisory travels in
    # `notice`; `senseLabel` is not a signal — C-001 revision 1).
    response = _create(gateway, "xylograph")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["normalisedLemma"] == "xylograph"
    assert body["notice"] and BEST_GUESS_FRAGMENT in body["notice"]
    # The reader-facing signal is `notice`, never the sense label (C-001 revision
    # 1); the label stays a non-empty human string.
    assert all(sense["senseLabel"] for sense in body["senses"])


def test_a_two_to_six_word_selection_routes_to_the_phrase_path(
    gateway: httpx2.Client,
) -> None:
    # FEAT-003: two to six words is a short phrase, not a normalised single word.
    response = _create(gateway, "a walk in the park")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["kind"] == "phrase"
    assert body["normalisedLemma"] is None
    assert body["senses"] == []


def test_exactly_six_words_is_still_a_phrase(gateway: httpx2.Client) -> None:
    response = _create(gateway, "one two three four five six")

    assert response.status_code == 200, response.text
    assert response.json()["kind"] == "phrase"


def test_punctuation_is_stripped_before_lookup(gateway: httpx2.Client) -> None:
    # FEAT-003 edge case: punctuation attached to the selection is stripped.
    response = _create(gateway, "coming,")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["normalisedLemma"] == "come"
    assert body["rawSelection"] == "coming,"


def test_a_hyphenated_compound_keeps_the_word_as_written(gateway: httpx2.Client) -> None:
    # FEAT-003 edge case: hyphenated compounds keep the base form as written.
    response = _create(gateway, "well-known")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["normalisedLemma"] == "well-known"
    assert body["notice"] and BEST_GUESS_FRAGMENT in body["notice"]


def test_an_empty_selection_is_refused(gateway: httpx2.Client) -> None:
    # C-001: 400 for an empty or whitespace selection.
    response = _create(gateway, "   ")

    assert response.status_code == 400, response.text
    assert response.json() == {
        "code": "empty_selection",
        "message": response.json()["message"],
    }


def test_over_the_phrase_limit_is_refused(gateway: httpx2.Client) -> None:
    # C-001: 400 for a selection over the six-word phrase limit.
    response = _create(gateway, "one two three four five six seven")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "phrase_limit_exceeded"


def test_a_missing_token_is_unauthorized(gateway: httpx2.Client) -> None:
    # C-001: 401 for a missing or invalid token.
    response = gateway.post(
        "/v1/lookups",
        json={
            "selection": "coming",
            "clientLookupId": "no-auth",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": True,
        },
    )

    assert response.status_code == 401, response.text
    assert set(response.json()) == {"code", "message"}


def test_a_reused_client_id_with_a_different_selection_conflicts(
    gateway: httpx2.Client,
) -> None:
    # C-001: 409 when clientLookupId is reused with a different selection.
    first = _create(gateway, "coming", client_id="dup-1")
    second = _create(gateway, "came", client_id="dup-1")

    assert first.status_code == 200, first.text
    assert second.status_code == 409, second.text
    assert second.json()["code"] == "client_lookup_id_conflict"


def test_replaying_the_same_client_id_returns_the_same_lookup(
    gateway: httpx2.Client,
) -> None:
    # C-001 idempotency: the same key and selection replays the recorded lookup.
    first = _create(gateway, "coming", client_id="replay-1")
    second = _create(gateway, "coming", client_id="replay-1")

    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["lookupId"] == second.json()["lookupId"]


def test_get_returns_the_lookup_for_its_owner(gateway: httpx2.Client) -> None:
    created = _create(gateway, "coming", client_id="get-1").json()

    response = gateway.get(f"/v1/lookups/{created['lookupId']}", headers=_auth())

    assert response.status_code == 200, response.text
    assert set(response.json()) == RESPONSE_KEYS
    assert response.json()["lookupId"] == created["lookupId"]


def test_get_hides_a_lookup_from_another_caller(gateway: httpx2.Client) -> None:
    # C-002: 404 when the lookup is unknown or not owned by the caller.
    created = _create(gateway, "coming", client_id="owner-1", subject="reader-1").json()

    response = gateway.get(f"/v1/lookups/{created['lookupId']}", headers=_auth("reader-2"))

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "lookup_not_found"


def test_get_an_unknown_lookup_is_not_found(gateway: httpx2.Client) -> None:
    response = gateway.get("/v1/lookups/lk_does_not_exist", headers=_auth())

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "lookup_not_found"

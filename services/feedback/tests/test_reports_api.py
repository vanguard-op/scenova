"""Client route tests for the report intake (C-013)."""

from __future__ import annotations

from feedback.app.models import LookupStatus
from feedback.tests.fakes import (
    AUTH,
    make_client,
    phrase_lookup,
    report_body,
    rig,
    word_lookup,
)


def test_a_report_is_queued_and_the_entry_is_held() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body())

    assert response.status_code == 202
    body = response.json()
    assert body["status"] == "queued"
    assert body["reportId"].startswith("rp_")
    assert rigged.library.held == ["le_1"]


def test_a_missing_token_is_unauthorized() -> None:
    with make_client() as client:
        response = client.post("/v1/reports", json=report_body())

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_unknown_reason_is_a_bad_request() -> None:
    with make_client() as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body(reason="rude"))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_note_over_the_bound_is_a_bad_request() -> None:
    # C-013: the optional note is at most 300 characters.
    with make_client() as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body(note="x" * 301))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_extra_field_is_a_bad_request() -> None:
    with make_client() as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body(accountId="someone"))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_lookup_is_not_found() -> None:
    with make_client(service=rig().service) as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body())

    assert response.status_code == 404
    assert response.json()["code"] == "lookup_not_found"


def test_a_lookup_without_a_served_clip_is_a_bad_request() -> None:
    rigged = rig(word_lookup(entries=(), status=LookupStatus.FALLBACK))

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body())

    assert response.status_code == 400
    assert response.json()["code"] == "no_clip_served"


def test_a_second_report_from_one_reader_conflicts() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service) as client:
        client.post("/v1/reports", headers=AUTH, json=report_body())
        response = client.post("/v1/reports", headers=AUTH, json=report_body(clientReportId="cr_2"))

    assert response.status_code == 409
    assert response.json()["code"] == "already_reported"


def test_a_phrase_report_is_accepted_with_no_shared_effect() -> None:
    rigged = rig(phrase_lookup())

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/reports", headers=AUTH, json=report_body())

    assert response.status_code == 202
    assert response.json()["status"] == "queued"
    assert rigged.library.held == []


def test_a_flood_is_rate_limited() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service, rate_limit=1) as client:
        first = client.post("/v1/reports", headers=AUTH, json=report_body())
        second = client.post("/v1/reports", headers=AUTH, json=report_body(clientReportId="cr_2"))

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"

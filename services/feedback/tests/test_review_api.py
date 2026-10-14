"""Wire tests for the curator review routes (C-014, C-015, C-016).

The intake records a report, then the review surface lists it and acts on it, so
the two halves are exercised through the same store as the deployed service.
"""

from __future__ import annotations

import httpx2

from feedback.tests.fakes import (
    AUTH,
    OPERATOR,
    OPERATOR_NO_MFA,
    OPERATOR_NO_ROLE,
    entry_view,
    full_rig,
    make_review_client,
    queue_body,
    report_body,
    word_lookup,
)


def _report(client: httpx2.Client) -> None:
    client.post("/v1/reports", headers=AUTH, json=report_body())


def test_a_missing_operator_session_is_unauthorized() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.get("/internal/review/queue")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_operator_without_the_curator_role_is_forbidden() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.get("/internal/review/queue", headers=OPERATOR_NO_ROLE)

    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"


def test_a_curator_session_without_a_second_factor_is_forbidden() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.get("/internal/review/queue", headers=OPERATOR_NO_MFA)

    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"


def test_the_reader_token_is_not_an_operator_session() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.get("/internal/review/queue", headers=AUTH)

    assert response.status_code == 403


def test_a_reported_entry_appears_in_the_queue_and_opens() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        queue = client.get("/internal/review/queue", headers=OPERATOR)
        entry = client.get("/internal/review/entries/le_1", headers=OPERATOR)

    assert queue.status_code == 200
    body = queue.json()
    assert body["openCount"] == 1
    assert body["page"] == 1
    assert body["pageCount"] == 1
    assert body["items"][0]["entryId"] == "le_1"
    assert body["items"][0]["reason"] == "wrong_meaning"
    assert body["items"][0]["state"] == "queued"

    assert entry.status_code == 200
    detail = entry.json()
    assert detail["entry"]["lemma"] == "come"
    assert detail["entry"]["clip"]["url"] == "https://cdn.example/clip_1.mp4"
    assert detail["reports"][0]["reason"] == "wrong_meaning"
    assert detail["state"] == "queued"


def test_the_queue_filters_by_reason_and_state() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        matching = client.get(
            "/internal/review/queue", headers=OPERATOR, params={"reason": "wrong_meaning"}
        )
        empty = client.get(
            "/internal/review/queue", headers=OPERATOR, params={"reason": "offensive"}
        )

    assert [item["entryId"] for item in matching.json()["items"]] == ["le_1"]
    assert empty.json()["items"] == []


def test_an_entry_with_nothing_queued_is_not_found() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.get("/internal/review/entries/le_1", headers=OPERATOR)

    assert response.status_code == 404
    assert response.json()["code"] == "review_entry_not_found"


def test_a_clear_action_returns_the_entry_to_serving() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view(status="held")})

    with make_review_client(rigged) as client:
        _report(client)
        response = client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(action="clear"),
        )

    assert response.status_code == 200
    body = response.json()
    assert body["actionId"].startswith("ma_")
    assert body["entryId"] == "le_1"
    assert body["status"] == "active"
    assert body["state"] == "actioned"
    assert rigged.library.statuses == [("le_1", "active")]


def test_an_edit_phrase_without_a_phrase_is_a_bad_request() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        response = client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(action="edit_phrase"),
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_note_over_the_bound_is_a_bad_request() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        response = client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(notes="x" * 501),
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_action_is_a_bad_request() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        response = client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(action="delete"),
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_stale_action_conflicts() -> None:
    rigged = full_rig(word_lookup(), entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        _report(client)
        client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(action="hold"),
        )
        response = client.post(
            "/internal/review/entries/le_1/actions",
            headers=OPERATOR,
            json=queue_body(action="clear", expectedState="queued"),
        )

    assert response.status_code == 409
    assert response.json()["code"] == "review_conflict"


def test_an_action_on_an_unknown_entry_is_not_found() -> None:
    rigged = full_rig(entries={"le_1": entry_view()})

    with make_review_client(rigged) as client:
        response = client.post(
            "/internal/review/entries/le_missing/actions",
            headers=OPERATOR,
            json=queue_body(),
        )

    assert response.status_code == 404
    assert response.json()["code"] == "review_entry_not_found"

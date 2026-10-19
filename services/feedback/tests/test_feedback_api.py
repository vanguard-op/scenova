"""Client route tests for the feedback intake (C-012)."""

from __future__ import annotations

from feedback.app.models import LookupStatus
from feedback.tests.fakes import (
    AUTH,
    SUBJECT,
    feedback_body,
    make_client,
    rig,
    word_lookup,
)


def test_health() -> None:
    # /health is the path the platform probes; /healthz stays as the local
    # image-smoke alias (ci/checks/build.sh).
    with make_client() as client:
        canonical = client.get("/health")
        alias = client.get("/healthz")

    assert canonical.status_code == 200
    assert canonical.json() == {"status": "ok", "service": "feedback"}
    assert alias.status_code == 200


def test_a_helpful_rating_is_accepted() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body())

    assert response.status_code == 202
    assert response.json() == {"recorded": True}
    # The lookup was confirmed against its owner before the rating was recorded.
    assert rigged.lookups.calls == [("lk_1", SUBJECT)]


def test_a_missing_token_is_unauthorized() -> None:
    with make_client() as client:
        response = client.post("/v1/feedback", json=feedback_body())

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_invalid_token_is_unauthorized() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/feedback",
            headers={"Authorization": "Bearer not-a-token"},
            json=feedback_body(),
        )

    assert response.status_code == 401


def test_an_unknown_rating_is_a_bad_request() -> None:
    with make_client() as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body(rating="great"))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_the_wrong_rating_is_refused_as_unknown() -> None:
    # `wrong` is no longer a writable rating: the reader reports a wrong meaning
    # through C-013 instead, so a request carrying it is refused like any other
    # unknown rating and records nothing (C-012 revision 1).
    rigged = rig(word_lookup())

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body(rating="wrong"))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"
    # Refused before any lookup was read, so nothing was recorded for the reader.
    assert rigged.lookups.calls == []
    assert rigged.store._feedback_by_client == {}


def test_a_missing_field_is_a_bad_request() -> None:
    body = feedback_body()
    body.pop("clientFeedbackId")

    with make_client() as client:
        response = client.post("/v1/feedback", headers=AUTH, json=body)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_extra_field_is_a_bad_request() -> None:
    with make_client() as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body(user_id="reader-1"))

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_lookup_is_not_found() -> None:
    with make_client(service=rig().service) as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body())

    assert response.status_code == 404
    assert response.json()["code"] == "lookup_not_found"


def test_a_lookup_without_a_served_clip_is_a_bad_request() -> None:
    rigged = rig(word_lookup(entries=(), status=LookupStatus.GENERATING))

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/feedback", headers=AUTH, json=feedback_body())

    assert response.status_code == 400
    assert response.json()["code"] == "no_clip_served"


def test_a_reused_key_with_a_different_rating_conflicts() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service) as client:
        client.post("/v1/feedback", headers=AUTH, json=feedback_body())
        response = client.post(
            "/v1/feedback", headers=AUTH, json=feedback_body(rating="not_helpful")
        )

    assert response.status_code == 409
    assert response.json()["code"] == "client_feedback_id_conflict"


def test_a_flood_is_rate_limited() -> None:
    rigged = rig(word_lookup())

    with make_client(service=rigged.service, rate_limit=1) as client:
        first = client.post("/v1/feedback", headers=AUTH, json=feedback_body())
        second = client.post(
            "/v1/feedback", headers=AUTH, json=feedback_body(clientFeedbackId="cf_2")
        )

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"

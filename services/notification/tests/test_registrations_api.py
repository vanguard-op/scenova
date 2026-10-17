"""Client intake tests for the push-registrations route (C-008)."""

from __future__ import annotations

from notification.app.lookups import LookupStatus
from notification.tests.fakes import (
    AUTH,
    SUBJECT,
    generating,
    make_client,
    register_body,
    rig,
)


def test_health() -> None:
    # /health is the path the platform probes; /healthz stays as the local
    # image-smoke alias (ci/checks/build.sh).
    with make_client() as client:
        canonical = client.get("/health")
        alias = client.get("/healthz")

    assert canonical.status_code == 200
    assert canonical.json() == {"status": "ok", "service": "notification"}
    assert alias.status_code == 200


def test_a_generating_lookup_registers_the_device() -> None:
    rigged = rig(generating())

    with make_client(service=rigged.service) as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert response.status_code == 202
    assert response.json() == {"registered": True}
    # The lookup was confirmed against its owner before the token was held.
    assert rigged.lookups.calls == [("lk_1", SUBJECT)]


def test_a_served_lookup_registers_the_device_for_a_regenerated_clip() -> None:
    # A served clip can be reported, and a report regenerates a clip for the
    # reporting reader that reaches them by the notice, so the device is held
    # for it (FEAT-011).
    statuses = {("lk_1", SUBJECT): LookupStatus.SERVED}

    with make_client(service=rig(statuses).service) as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert response.status_code == 202
    assert response.json() == {"registered": True}


def test_a_fallback_lookup_needs_no_notice() -> None:
    statuses = {("lk_1", SUBJECT): LookupStatus.FALLBACK}

    with make_client(service=rig(statuses).service) as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert response.json() == {"registered": False}


def test_an_unknown_lookup_is_refused() -> None:
    with make_client(service=rig().service) as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert response.status_code == 400
    assert response.json()["code"] == "unknown_lookup"


def test_a_lookup_service_outage_does_not_claim_a_notice() -> None:
    with make_client(service=rig(generating(), lookup_unavailable=True).service) as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert response.status_code == 202
    assert response.json() == {"registered": False}


def test_a_missing_token_is_refused() -> None:
    body = register_body()
    body.pop("token")

    with make_client() as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=body)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unreadable_token_is_refused() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/push-registrations", headers=AUTH, json=register_body(token="has a space")
        )

    assert response.status_code == 400
    assert response.json()["code"] == "unreadable_token"


def test_a_missing_lookup_id_is_refused() -> None:
    body = register_body()
    body.pop("lookupId")

    with make_client() as client:
        response = client.post("/v1/push-registrations", headers=AUTH, json=body)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_platform_is_refused() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/push-registrations", headers=AUTH, json=register_body(platform="web")
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_extra_field_is_refused() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/push-registrations",
            headers=AUTH,
            json=register_body(user_id="reader-1"),
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_missing_token_is_unauthenticated() -> None:
    with make_client() as client:
        response = client.post("/v1/push-registrations", json=register_body())

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_invalid_token_is_unauthenticated() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/push-registrations",
            headers={"Authorization": "Bearer not-a-token"},
            json=register_body(),
        )

    assert response.status_code == 401


def test_a_flood_is_rate_limited() -> None:
    rigged = rig(generating())

    with make_client(service=rigged.service, rate_limit=1) as client:
        first = client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        second = client.post("/v1/push-registrations", headers=AUTH, json=register_body())

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"

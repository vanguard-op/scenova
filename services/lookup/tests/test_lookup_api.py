"""Internal API tests for the lookup service (HTTP status and shape mapping)."""

from __future__ import annotations

from fastapi.testclient import TestClient

from lookup.app.api import create_app
from lookup.app.config import Settings
from lookup.app.inventory import build_default_inventory
from lookup.app.library import InMemoryLibrary
from lookup.app.service import LookupService
from lookup.app.store import InMemoryLookupStore
from lookup.tests.fakes import RecordingEntitlementClient, RecordingGenerationClient

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _client(
    require_internal_auth: bool = True,
    entitlement: RecordingEntitlementClient | None = None,
) -> TestClient:
    service = LookupService(
        inventory=build_default_inventory(),
        store=InMemoryLookupStore(),
        library=InMemoryLibrary(),
        generation=RecordingGenerationClient(),
        entitlement=entitlement if entitlement is not None else RecordingEntitlementClient(),
    )
    return TestClient(
        create_app(
            settings=Settings(require_internal_auth=require_internal_auth),
            service=service,
        )
    )


def _payload(
    selection: str, client_id: str = "client-1", *, is_anonymous: bool = False
) -> dict[str, object]:
    return {
        "selection": selection,
        "clientLookupId": client_id,
        "platform": "android",
        "locale": "en",
        "consentModelProcessing": True,
        "subject": "reader-1",
        "isAnonymous": is_anonymous,
    }


def test_health() -> None:
    # /health is the path the platform probes; /healthz stays as the local
    # image-smoke alias (ci/checks/build.sh).
    with _client() as client:
        canonical = client.get("/health")
        alias = client.get("/healthz")

    assert canonical.status_code == 200
    assert canonical.json() == {"status": "ok", "service": "lookup"}
    assert alias.status_code == 200


def test_internal_routes_reject_a_missing_audience() -> None:
    with _client() as client:
        response = client.post("/internal/lookups", json=_payload("coming"))

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_create_lookup_returns_the_contract_shape() -> None:
    with _client() as client:
        response = client.post("/internal/lookups", json=_payload("coming"), headers=_INTERNAL)

    assert response.status_code == 200
    body = response.json()
    assert body["normalisedLemma"] == "come"
    assert body["kind"] == "word"
    assert set(body) == {
        "lookupId",
        "kind",
        "rawSelection",
        "normalisedLemma",
        "status",
        "senses",
        "notice",
        "correlationId",
        "allowance",
    }


def test_create_lookup_carries_the_reader_allowance() -> None:
    meter = RecordingEntitlementClient(lookups_used=3, lookups_limit=20)

    with _client(entitlement=meter) as client:
        response = client.post("/internal/lookups", json=_payload("coming"), headers=_INTERNAL)

    assert response.json()["allowance"] == {
        "used": 3,
        "limit": 20,
        "periodEnd": "2026-11-15T12:00:00+00:00",
    }


def test_create_lookup_for_a_signed_out_reader_carries_no_allowance() -> None:
    with _client() as client:
        response = client.post(
            "/internal/lookups", json=_payload("coming", is_anonymous=True), headers=_INTERNAL
        )

    assert response.json()["allowance"] is None


def test_get_lookup_omits_the_allowance() -> None:
    with _client() as client:
        created = client.post(
            "/internal/lookups", json=_payload("coming"), headers=_INTERNAL
        ).json()
        found = client.get(
            f"/internal/lookups/{created['lookupId']}",
            params={"subject": "reader-1"},
            headers=_INTERNAL,
        )

    assert "allowance" not in found.json()


def test_empty_selection_is_a_bad_request() -> None:
    with _client() as client:
        response = client.post("/internal/lookups", json=_payload("   "), headers=_INTERNAL)

    assert response.status_code == 400
    assert response.json()["code"] == "empty_selection"


def test_over_the_phrase_limit_is_a_bad_request() -> None:
    with _client() as client:
        response = client.post(
            "/internal/lookups",
            json=_payload("one two three four five six seven"),
            headers=_INTERNAL,
        )

    assert response.status_code == 400
    assert response.json()["code"] == "phrase_limit_exceeded"


def test_over_the_80_character_bound_is_a_bad_request() -> None:
    with _client() as client:
        response = client.post("/internal/lookups", json=_payload("a" * 81), headers=_INTERNAL)

    assert response.status_code == 400
    assert response.json()["code"] == "selection_too_long"


def test_a_reused_client_id_conflicts() -> None:
    with _client() as client:
        client.post("/internal/lookups", json=_payload("coming", "c-1"), headers=_INTERNAL)
        response = client.post("/internal/lookups", json=_payload("came", "c-1"), headers=_INTERNAL)

    assert response.status_code == 409
    assert response.json()["code"] == "client_lookup_id_conflict"


def test_get_returns_the_lookup_and_hides_it_from_another_caller() -> None:
    with _client() as client:
        created = client.post(
            "/internal/lookups", json=_payload("coming"), headers=_INTERNAL
        ).json()
        found = client.get(
            f"/internal/lookups/{created['lookupId']}",
            params={"subject": "reader-1"},
            headers=_INTERNAL,
        )
        hidden = client.get(
            f"/internal/lookups/{created['lookupId']}",
            params={"subject": "reader-2"},
            headers=_INTERNAL,
        )

    assert found.status_code == 200
    assert found.json()["lookupId"] == created["lookupId"]
    assert hidden.status_code == 404

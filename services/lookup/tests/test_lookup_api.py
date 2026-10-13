"""Internal API tests for the lookup service (HTTP status and shape mapping)."""

from __future__ import annotations

from fastapi.testclient import TestClient

from lookup.app.api import create_app
from lookup.app.config import Settings
from lookup.app.inventory import build_default_inventory
from lookup.app.library import InMemoryLibrary
from lookup.app.service import LookupService
from lookup.app.store import InMemoryLookupStore
from lookup.tests.fakes import RecordingGenerationClient

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _client(require_internal_auth: bool = True) -> TestClient:
    service = LookupService(
        inventory=build_default_inventory(),
        store=InMemoryLookupStore(),
        library=InMemoryLibrary(),
        generation=RecordingGenerationClient(),
    )
    return TestClient(
        create_app(
            settings=Settings(require_internal_auth=require_internal_auth),
            service=service,
        )
    )


def _payload(selection: str, client_id: str = "client-1") -> dict[str, object]:
    return {
        "selection": selection,
        "clientLookupId": client_id,
        "platform": "android",
        "locale": "en",
        "consentModelProcessing": True,
        "subject": "reader-1",
    }


def test_healthz() -> None:
    with _client() as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "lookup"}


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
    }


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

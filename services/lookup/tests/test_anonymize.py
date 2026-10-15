"""Tests for the lookup anonymization seam (FEAT-013; nfr.md "Privacy & Compliance").

A lookup is personal data (schema "Lookup": `accountId`, `rawSelection`,
`normalisedLemma`), so a reader's account deletion anonymizes their lookups: the
selection and the identity go, and the record is left under a sentinel no reader
can hold. The seam is internal, never reachable from the client, and idempotent.
"""

from __future__ import annotations

import asyncio

from fastapi.testclient import TestClient

from lookup.app.api import create_app
from lookup.app.config import Settings
from lookup.app.inventory import build_default_inventory
from lookup.app.library import InMemoryLibrary
from lookup.app.service import LookupService
from lookup.app.store import ANONYMIZED_SUBJECT, InMemoryLookupStore
from lookup.tests.fakes import RecordingEntitlementClient, RecordingGenerationClient

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _rig() -> tuple[TestClient, InMemoryLookupStore]:
    store = InMemoryLookupStore()
    service = LookupService(
        inventory=build_default_inventory(),
        store=store,
        library=InMemoryLibrary(),
        generation=RecordingGenerationClient(),
        entitlement=RecordingEntitlementClient(),
    )
    client = TestClient(create_app(settings=Settings(), service=service))
    return client, store


def _payload(selection: str, client_id: str, subject: str = "reader-1") -> dict[str, object]:
    return {
        "selection": selection,
        "clientLookupId": client_id,
        "platform": "android",
        "locale": "en",
        "consentModelProcessing": True,
        "subject": subject,
        "isAnonymous": False,
    }


def _create(client: TestClient, selection: str, client_id: str, subject: str = "reader-1") -> str:
    response = client.post(
        "/internal/lookups", json=_payload(selection, client_id, subject), headers=_INTERNAL
    )
    assert response.status_code == 200, response.text
    lookup_id: str = response.json()["lookupId"]
    return lookup_id


def _anonymize(client: TestClient, subject: str) -> dict[str, object]:
    response = client.post(
        "/internal/lookups/anonymize", json={"subject": subject}, headers=_INTERNAL
    )
    assert response.status_code == 200, response.text
    return response.json()  # type: ignore[no-any-return]


def test_the_seam_anonymizes_the_readers_lookups() -> None:
    client, store = _rig()
    with client:
        created = client.post(
            "/internal/lookups", json=_payload("coming", "c-1"), headers=_INTERNAL
        ).json()
        result = _anonymize(client, "reader-1")

    assert result == {"anonymized": 1}
    stored = asyncio.run(store.get(created["lookupId"]))
    assert stored is not None
    assert stored.subject == ANONYMIZED_SUBJECT
    assert stored.raw_selection == ""
    assert stored.normalised_lemma is None
    assert stored.senses == ()
    # The outcome and the kind survive, so the reader's usage is an anonymized
    # count rather than a lost record.
    assert stored.kind.value == "word"
    assert stored.status.value == created["status"]


def test_the_seam_severs_the_lookups_ownership() -> None:
    client, _ = _rig()
    with client:
        lookup_id = _create(client, "coming", "c-1")
        _anonymize(client, "reader-1")
        found = client.get(
            f"/internal/lookups/{lookup_id}", params={"subject": "reader-1"}, headers=_INTERNAL
        )

    assert found.status_code == 404


def test_the_seam_requires_an_internal_identity() -> None:
    client, _ = _rig()
    with client:
        response = client.post("/internal/lookups/anonymize", json={"subject": "reader-1"})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_only_the_subjects_lookups_go() -> None:
    client, store = _rig()
    with client:
        kept = _create(client, "coming", "c-1", subject="reader-2")
        _create(client, "going", "c-2", subject="reader-1")
        result = _anonymize(client, "reader-1")

    assert result == {"anonymized": 1}
    stored = asyncio.run(store.get(kept))
    assert stored is not None
    assert stored.subject == "reader-2"
    assert stored.raw_selection == "coming"


def test_a_re_run_anonymizes_nothing_more() -> None:
    client, _ = _rig()
    with client:
        _create(client, "coming", "c-1")
        first = _anonymize(client, "reader-1")
        second = _anonymize(client, "reader-1")

    assert first == {"anonymized": 1}
    assert second == {"anonymized": 0}


def test_the_dropped_idempotency_key_starts_a_fresh_lookup() -> None:
    # The clientLookupId belonged to the reader who made the lookup, so it is
    # dropped with them rather than left mapped to the anonymized record.
    client, _ = _rig()
    with client:
        first = _create(client, "coming", "c-1")
        _anonymize(client, "reader-1")
        second = _create(client, "coming", "c-1")

    assert first != second

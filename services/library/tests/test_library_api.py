"""Internal API tests for the shared word-clip library (FEAT-006).

The lookup and pipeline services are the callers, so these tests exercise the
routes as those services call them: store a word clip, read it back by sense key,
and move an entry's status after review.
"""

from __future__ import annotations

import httpx2
from fastapi.testclient import TestClient

from library.app.api import create_app
from library.app.config import Settings

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _client(*, require_internal_auth: bool = True) -> TestClient:
    return TestClient(create_app(settings=Settings(require_internal_auth=require_internal_auth)))


def _entry(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "id": "le_1",
        "lemma": "come",
        "partOfSpeech": "verb",
        "senseLabel": "arrive",
        "glossPhrase": "to move toward a place",
        "clipAssetId": "clip_1",
        "status": "active",
        "source": "generated",
        "createdAt": "2026-10-13T00:00:00+00:00",
        "updatedAt": "2026-10-13T00:00:00+00:00",
    }
    body.update(overrides)
    return body


def _asset(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "id": "clip_1",
        "durationSeconds": 3.0,
        "resolution": "360p",
        "storageKey": "clips/clip_1.mp4",
        "url": "https://cdn.example/clip_1.mp4",
        "hasAudio": False,
        "synthIdWatermark": True,
        "createdAt": "2026-10-13T00:00:00+00:00",
    }
    body.update(overrides)
    return body


def _store(client: TestClient, **overrides: object) -> httpx2.Response:
    return client.post(
        "/internal/library/entries",
        headers=_INTERNAL,
        json={"entry": _entry(**overrides), "asset": _asset()},
    )


def _find(client: TestClient, *, lemma: str = "come") -> httpx2.Response:
    return client.get(
        "/internal/library/entries",
        headers=_INTERNAL,
        params={"lemma": lemma, "senseLabel": "arrive", "partOfSpeech": "verb"},
    )


def test_healthz() -> None:
    with _client() as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "library"}


def test_the_routes_reject_a_missing_audience() -> None:
    with _client() as client:
        stored = client.post(
            "/internal/library/entries",
            json={"entry": _entry(), "asset": _asset()},
        )
        found = client.get(
            "/internal/library/entries",
            params={"lemma": "come", "senseLabel": "arrive", "partOfSpeech": "verb"},
        )

    assert stored.status_code == 401
    assert found.status_code == 401
    assert stored.json()["code"] == "unauthorized"


def test_a_stored_word_clip_is_served_by_its_sense_key() -> None:
    with _client() as client:
        stored = _store(client)
        found = _find(client)

    assert stored.status_code == 202
    assert stored.json() == {"entryId": "le_1", "status": "active"}
    assert found.status_code == 200
    entry = found.json()["entry"]
    assert entry["entryId"] == "le_1"
    assert entry["status"] == "active"
    assert entry["glossPhrase"] == "to move toward a place"
    assert entry["clip"] == {
        "url": "https://cdn.example/clip_1.mp4",
        "durationSeconds": 3.0,
        "resolution": "360p",
        "hasAudio": False,
    }


def test_an_unknown_sense_key_is_a_miss() -> None:
    with _client() as client:
        found = _find(client, lemma="xylograph")

    assert found.status_code == 200
    assert found.json() == {"entry": None}


def test_a_retired_entry_is_kept_and_reported_as_retired() -> None:
    # The lookup must be able to tell a retired entry from an absent one, so the
    # library keeps it rather than dropping it (FEAT-006).
    with _client() as client:
        _store(client)
        retired = client.patch(
            "/internal/library/entries/le_1",
            headers=_INTERNAL,
            json={"status": "retired"},
        )
        found = _find(client)

    assert retired.status_code == 200
    assert retired.json() == {"entryId": "le_1", "status": "retired"}
    assert found.json()["entry"]["status"] == "retired"


def test_retiring_an_unknown_entry_is_not_found() -> None:
    with _client() as client:
        response = client.patch(
            "/internal/library/entries/le_missing",
            headers=_INTERNAL,
            json={"status": "retired"},
        )

    assert response.status_code == 404
    assert response.json()["code"] == "entry_not_found"


def test_a_clip_over_the_four_second_cap_is_refused() -> None:
    with _client() as client:
        response = client.post(
            "/internal/library/entries",
            headers=_INTERNAL,
            json={"entry": _entry(), "asset": _asset(durationSeconds=5.0)},
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_clip_below_the_three_second_floor_is_refused() -> None:
    # schema.md "ClipAsset": the pinned model produces three to four seconds, so
    # an asset shorter than three is not a clip the library will hold.
    with _client() as client:
        response = client.post(
            "/internal/library/entries",
            headers=_INTERNAL,
            json={"entry": _entry(), "asset": _asset(durationSeconds=2.0)},
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_malformed_entry_is_refused() -> None:
    with _client() as client:
        response = client.post(
            "/internal/library/entries",
            headers=_INTERNAL,
            json={"entry": {"id": "le_1"}, "asset": _asset()},
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_status_outside_the_review_states_is_refused() -> None:
    with _client() as client:
        _store(client)
        response = client.patch(
            "/internal/library/entries/le_1",
            headers=_INTERNAL,
            json={"status": "gone"},
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"

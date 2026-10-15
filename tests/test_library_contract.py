"""Integration and acceptance tests for the shared word-clip library.

Verifies FEAT-006 end to end against the frozen internal contracts C-009
(`POST /internal/library/entries`), C-010 (`GET /internal/library/entries`), and
C-011 (`PATCH /internal/library/entries/{entryId}`), plus C-017
(`GET /internal/library/entries/{entryId}`, the review service's by-id read), and
the acceptance criteria and edge cases in the feature doc.

The library is exercised two ways:

- Against the client-path stack, a seeded entry is served through the real
  gateway and lookup service (C-001), and the contract routes are hit directly as
  the pipeline and content review service call them. `GEMINI_API_KEY` is unset,
  so no clip can be generated: a miss resolves to the shipped fallback, and the
  store / serve half of the criterion is driven by seeding C-009 exactly as the
  pipeline writes it.
- Against the generation-loop stack, the external model provider (C-004, C-005)
  is a local double, so a miss is generated, written to the library, and served
  to a later reader — the whole loop, across the lookup, pipeline, and library
  services.
"""

from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

import httpx2
import pytest

from tests.conftest import INTERNAL_AUDIENCE

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

INTERNAL = {"x-internal-audience": INTERNAL_AUDIENCE}
_NOW = "2026-10-13T00:00:00+00:00"


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
) -> httpx2.Response:
    return gateway.post(
        "/v1/lookups",
        headers=_auth(subject),
        json={
            "selection": selection,
            "clientLookupId": client_id or f"id-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": consent,
        },
    )


def _entry(
    entry_id: str,
    *,
    lemma: str,
    sense_label: str,
    part_of_speech: str,
    gloss: str = "a sense in context",
) -> dict[str, Any]:
    return {
        "id": entry_id,
        "lemma": lemma,
        "partOfSpeech": part_of_speech,
        "senseLabel": sense_label,
        "glossPhrase": gloss,
        "clipAssetId": f"clip_{entry_id}",
        "status": "active",
        "source": "generated",
        "createdAt": _NOW,
        "updatedAt": _NOW,
    }


def _asset(entry_id: str, *, duration: float = 3.0) -> dict[str, Any]:
    return {
        "id": f"clip_{entry_id}",
        "durationSeconds": duration,
        "resolution": "360p",
        "storageKey": f"clips/{entry_id}.mp4",
        "url": f"https://cdn.example/{entry_id}.mp4",
        "hasAudio": False,
        "synthIdWatermark": True,
        "createdAt": _NOW,
    }


def _store(
    library: httpx2.Client,
    entry: dict[str, Any],
    asset: dict[str, Any] | None = None,
    *,
    expected: int = 202,
) -> httpx2.Response:
    response = library.post(
        "/internal/library/entries",
        headers=INTERNAL,
        json={"entry": entry, "asset": asset or _asset(entry["id"])},
    )
    assert response.status_code == expected, response.text
    return response


def _find(
    library: httpx2.Client,
    *,
    lemma: str,
    sense_label: str,
    part_of_speech: str,
) -> httpx2.Response:
    return library.get(
        "/internal/library/entries",
        headers=INTERNAL,
        params={
            "lemma": lemma,
            "senseLabel": sense_label,
            "partOfSpeech": part_of_speech,
        },
    )


def _poll_until_settled(
    gateway: httpx2.Client,
    lookup_id: str,
    *,
    subject: str = "reader-1",
    attempts: int = 60,
    delay: float = 0.25,
) -> dict[str, Any]:
    body: dict[str, Any] = {}
    for _ in range(attempts):
        response = gateway.get(f"/v1/lookups/{lookup_id}", headers=_auth(subject))
        assert response.status_code == 200, response.text
        body = response.json()
        if body["status"] != "generating":
            return body
        time.sleep(delay)
    pytest.fail(f"lookup {lookup_id} stayed 'generating': {body}")


def _wait_for_provider_call(
    stub: httpx2.Client,
    *,
    name: str,
    minimum: int = 1,
    attempts: int = 100,
    delay: float = 0.05,
) -> None:
    """Wait until the model-provider double has answered at least `minimum` calls.

    The double counts a call when it answers, so waiting on a counter lets a test
    act at a known point inside a generation instead of racing its completion.
    """

    calls: dict[str, int] = {}
    for _ in range(attempts):
        calls = stub.get("/test/calls").json()
        if calls.get(name, 0) >= minimum:
            return
        time.sleep(delay)
    pytest.fail(f"the model provider double never made {minimum} '{name}' call(s): {calls}")


# --- FEAT-006 acceptance criteria — the store / serve half --------------------


def test_a_word_in_the_library_is_served_to_any_reader(
    gateway: httpx2.Client,
    library: httpx2.Client,
) -> None:
    # FEAT-006: a word already in the library is served, with its stored clip,
    # without a new generation — for any reader.
    _store(
        library,
        _entry(
            "le_house",
            lemma="house",
            sense_label="building",
            part_of_speech="noun",
            gloss="a place where people live",
        ),
    )

    first = _create(gateway, "houses", client_id="lib-hit-houses")
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["status"] == "served"
    assert body["senses"] and all(sense["clip"] is not None for sense in body["senses"])
    sense = body["senses"][0]
    assert sense["entryId"] == "le_house"
    assert sense["glossPhrase"] == "a place where people live"
    assert sense["clip"]["url"] == "https://cdn.example/le_house.mp4"
    assert sense["clip"]["resolution"] == "360p"

    second = _create(gateway, "house", client_id="lib-hit-house", subject="reader-2")
    assert second.status_code == 200, second.text
    assert second.json()["status"] == "served"
    assert second.json()["senses"][0]["entryId"] == "le_house"


def test_a_word_absent_from_the_library_starts_a_generation(
    gateway: httpx2.Client,
) -> None:
    # FEAT-006: a word absent from the library is handed to generation; the reader
    # never waits (NFR-002, NFR-003).
    response = _create(gateway, "seeing", client_id="lib-miss-seeing")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "generating"
    assert body["senses"], "the word and phrase still show while the clip generates"
    assert all(sense["clip"] is None for sense in body["senses"])


def test_an_unreachable_library_falls_back_to_generation(
    library_down_gateway: httpx2.Client,
) -> None:
    # FEAT-006 edge case: when the shared library cannot be reached, the lookup
    # falls back to generation rather than failing; the word and phrase still
    # show and the reader is never blocked.
    response = _create(library_down_gateway, "word", client_id="lib-down-1")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] in {"generating", "fallback"}
    assert body["senses"], "the word and phrase still show without the shared library"
    assert all(sense["clip"] is None for sense in body["senses"])


def test_a_retired_entry_is_not_served_and_is_regenerated(
    gateway: httpx2.Client,
    library: httpx2.Client,
) -> None:
    # FEAT-006: a stored clip retired after review is not served on the next
    # lookup; a fresh generation is started instead.
    _store(
        library,
        _entry(
            "le_light",
            lemma="light",
            sense_label="illumination",
            part_of_speech="noun",
            gloss="the brightness that lets you see",
        ),
    )
    retired = library.patch(
        "/internal/library/entries/le_light",
        headers=INTERNAL,
        json={"status": "retired"},
    )
    assert retired.status_code == 200, retired.text
    assert retired.json() == {"entryId": "le_light", "status": "retired"}

    body = _create(gateway, "lights", client_id="lib-retired-lights").json()

    assert body["status"] == "generating"
    sense = body["senses"][0]
    assert sense["entryId"] is None, "the retired entry is not served"
    assert sense["clip"] is None


def test_a_held_status_is_refused_and_the_entry_keeps_serving(
    gateway: httpx2.Client,
    library: httpx2.Client,
) -> None:
    # The library holds only `active` and `retired`: an entry under review keeps
    # serving while a curator decides, so there is no `held` status (FEAT-006
    # edge case, FEAT-015, C-011). The superseded status is refused rather than
    # accepted, and the entry it named is untouched.
    _store(
        library,
        _entry(
            "le_happy",
            lemma="happy",
            sense_label="glad",
            part_of_speech="adjective",
            gloss="feeling or showing pleasure",
        ),
    )
    held = library.patch(
        "/internal/library/entries/le_happy",
        headers=INTERNAL,
        json={"status": "held"},
    )

    assert held.status_code == 400, held.text
    assert held.json()["code"] == "invalid_request"

    found = _find(library, lemma="happy", sense_label="glad", part_of_speech="adjective")
    assert found.json()["entry"]["status"] == "active"
    body = _create(gateway, "happier", client_id="lib-review-happier").json()
    assert body["status"] == "served", "the entry under review still serves"
    assert body["senses"][0]["entryId"] == "le_happy"


def test_a_retired_entry_is_kept_and_reported_by_the_library(
    library: httpx2.Client,
) -> None:
    # The lookup must tell a retired entry from an absent one, so the library keeps
    # it and reports its status rather than dropping it (FEAT-006, C-010, C-011).
    _store(
        library,
        _entry(
            "le_read",
            lemma="read",
            sense_label="look_at_words",
            part_of_speech="verb",
        ),
    )
    library.patch("/internal/library/entries/le_read", headers=INTERNAL, json={"status": "retired"})

    found = _find(library, lemma="read", sense_label="look_at_words", part_of_speech="verb")

    assert found.status_code == 200, found.text
    entry = found.json()["entry"]
    assert entry is not None
    assert entry["entryId"] == "le_read"
    assert entry["status"] == "retired"


# --- C-009: POST /internal/library/entries -----------------------------------


def test_storing_an_entry_returns_its_id_and_status(library: httpx2.Client) -> None:
    response = _store(
        library,
        _entry(
            "le_write",
            lemma="write",
            sense_label="put_words_down",
            part_of_speech="verb",
        ),
    )

    assert response.json() == {"entryId": "le_write", "status": "active"}


def test_the_entry_write_conforms_to_contract_c009(library: httpx2.Client) -> None:
    # C-009 freezes the write as an entry plus the clip asset it references, and
    # acknowledges it with the entry's id and status.
    documented_body: dict[str, Any] = {
        "entry": {
            "id": "le_dictionary",
            "lemma": "dictionary",
            "partOfSpeech": "noun",
            "senseLabel": "reference",
            "glossPhrase": "a book of words and meanings",
            "clipAssetId": "clip_dictionary",
            "status": "active",
            "source": "generated",
            "createdAt": _NOW,
            "updatedAt": _NOW,
        },
        "asset": {
            "id": "clip_dictionary",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "storageKey": "clips/c009.mp4",
            "url": "https://cdn.example/c009.mp4",
            "hasAudio": False,
            "synthIdWatermark": True,
            "createdAt": _NOW,
        },
    }

    response = library.post("/internal/library/entries", headers=INTERNAL, json=documented_body)

    assert response.status_code == 202, response.text
    assert response.json() == {"entryId": "le_dictionary", "status": "active"}

    stored = _find(library, lemma="dictionary", sense_label="reference", part_of_speech="noun")
    assert stored.json()["entry"]["glossPhrase"] == "a book of words and meanings"


def test_a_flat_entry_write_is_refused(library: httpx2.Client) -> None:
    # C-009 freezes the write as an entry plus its asset, never a flat entry
    # carrying a nested `clip`; the superseded shape is refused rather than
    # silently accepted, so a caller on the old shape cannot write an entry whose
    # clip asset was dropped.
    flat: dict[str, Any] = {
        "lemma": "flat",
        "senseLabel": "shape",
        "partOfSpeech": "noun",
        "glossPhrase": "a superseded body",
        "source": "generated",
        "clip": {
            "storageKey": "clips/flat.mp4",
            "url": "https://cdn.example/flat.mp4",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "hasAudio": False,
            "synthIdWatermark": True,
        },
    }

    response = library.post("/internal/library/entries", headers=INTERNAL, json=flat)

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"


def test_upserting_a_sense_key_replaces_the_entry_it_held(library: httpx2.Client) -> None:
    # C-009: upserts by the lemma and sense key, so a replacement supersedes the
    # entry the key held (FEAT-006).
    _store(
        library,
        _entry(
            "le_word_old",
            lemma="word",
            sense_label="unit_of_language",
            part_of_speech="noun",
            gloss="an old gloss",
        ),
    )
    _store(
        library,
        _entry(
            "le_word_new",
            lemma="word",
            sense_label="unit_of_language",
            part_of_speech="noun",
            gloss="a new gloss",
        ),
    )

    found = _find(library, lemma="word", sense_label="unit_of_language", part_of_speech="noun")

    entry = found.json()["entry"]
    assert entry["entryId"] == "le_word_new"
    assert entry["glossPhrase"] == "a new gloss"


def test_the_library_routes_require_the_internal_audience(library: httpx2.Client) -> None:
    # C-009, C-010, C-011: internal service identity only; never reachable from
    # the client.
    stored = library.post(
        "/internal/library/entries",
        json={
            "entry": _entry(
                "le_no_auth",
                lemma="make",
                sense_label="create",
                part_of_speech="verb",
            ),
            "asset": _asset("le_no_auth"),
        },
    )
    found = library.get(
        "/internal/library/entries",
        params={"lemma": "make", "senseLabel": "create", "partOfSpeech": "verb"},
    )
    updated = library.patch("/internal/library/entries/le_no_auth", json={"status": "active"})

    assert stored.status_code == 401 and stored.json()["code"] == "unauthorized"
    assert found.status_code == 401
    assert updated.status_code == 401


def test_a_clip_over_the_four_second_cap_is_refused(library: httpx2.Client) -> None:
    response = _store(
        library,
        _entry(
            "le_make",
            lemma="make",
            sense_label="create",
            part_of_speech="verb",
        ),
        _asset("le_make", duration=5.0),
        expected=400,
    )

    assert response.json()["code"] == "invalid_request"


def test_a_malformed_entry_is_refused(library: httpx2.Client) -> None:
    response = library.post(
        "/internal/library/entries",
        headers=INTERNAL,
        json={"entry": {"id": "le_broken"}, "asset": _asset("le_broken")},
    )

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"


# --- C-010: GET /internal/library/entries ------------------------------------


def test_the_library_serves_an_active_entry_with_its_clip(library: httpx2.Client) -> None:
    _store(
        library,
        _entry(
            "le_quick",
            lemma="quick",
            sense_label="fast",
            part_of_speech="adjective",
            gloss="moving or happening fast",
        ),
    )

    found = _find(library, lemma="quick", sense_label="fast", part_of_speech="adjective")

    assert found.status_code == 200, found.text
    entry = found.json()["entry"]
    assert entry["entryId"] == "le_quick"
    assert entry["status"] == "active"
    assert entry["glossPhrase"] == "moving or happening fast"
    assert set(entry["clip"]) == {"url", "durationSeconds", "resolution", "hasAudio"}
    assert entry["clip"]["url"] == "https://cdn.example/le_quick.mp4"


def test_the_entry_read_conforms_to_contract_c010(library: httpx2.Client) -> None:
    # C-010 freezes the served entry as exactly what the lookup needs to serve a
    # clip: the entry id, its review status, the gloss phrase, and the clip. The
    # lemma, sense label, and part of speech are the query, not part of the
    # response.
    _store(
        library,
        _entry(
            "le_lucky",
            lemma="lucky",
            sense_label="fortunate",
            part_of_speech="adjective",
            gloss="having good luck",
        ),
    )

    found = _find(library, lemma="lucky", sense_label="fortunate", part_of_speech="adjective")

    assert found.status_code == 200, found.text
    entry = found.json()["entry"]
    assert set(entry) == {
        "entryId",
        "status",
        "glossPhrase",
        "clip",
    }, f"C-010 entry fields differ: {sorted(entry)}"
    assert set(entry["clip"]) == {"url", "durationSeconds", "resolution", "hasAudio"}
    assert entry["entryId"] == "le_lucky"
    assert entry["status"] == "active"
    assert entry["glossPhrase"] == "having good luck"


def test_an_unknown_sense_key_reads_as_null(library: httpx2.Client) -> None:
    found = _find(
        library,
        lemma="nonexistent",
        sense_label="nothing",
        part_of_speech="other",
    )

    assert found.status_code == 200, found.text
    assert found.json() == {"entry": None}


# --- C-011: PATCH /internal/library/entries/{entryId} ------------------------


def test_a_review_action_moves_an_entrys_status(library: httpx2.Client) -> None:
    _store(
        library,
        _entry(
            "le_go",
            lemma="go",
            sense_label="move",
            part_of_speech="verb",
        ),
    )

    updated = library.patch(
        "/internal/library/entries/le_go",
        headers=INTERNAL,
        json={"status": "retired"},
    )

    assert updated.status_code == 200, updated.text
    assert updated.json() == {"entryId": "le_go", "status": "retired"}
    found = _find(library, lemma="go", sense_label="move", part_of_speech="verb")
    assert found.json()["entry"]["status"] == "retired"


def test_retiring_an_unknown_entry_is_not_found(library: httpx2.Client) -> None:
    response = library.patch(
        "/internal/library/entries/le_missing",
        headers=INTERNAL,
        json={"status": "retired"},
    )

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "entry_not_found"


def test_a_status_outside_the_review_states_is_refused(library: httpx2.Client) -> None:
    _store(
        library,
        _entry(
            "le_good",
            lemma="good",
            sense_label="fine",
            part_of_speech="adjective",
        ),
    )

    response = library.patch(
        "/internal/library/entries/le_good",
        headers=INTERNAL,
        json={"status": "gone"},
    )

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"


# --- C-017: GET /internal/library/entries/{entryId} --------------------------


def test_the_by_id_entry_read_conforms_to_contract_c017(library: httpx2.Client) -> None:
    # C-017 freezes the by-id read the review service uses for an entry's detail:
    # the queue holds only an entry id, so the sense key C-010 needs is not at
    # hand. It carries the word, sense, phrase, status, and clip.
    _store(
        library,
        _entry(
            "le_phone",
            lemma="phone",
            sense_label="device",
            part_of_speech="noun",
            gloss="a device for talking to someone far away",
        ),
    )

    response = library.get("/internal/library/entries/le_phone", headers=INTERNAL)

    assert response.status_code == 200, response.text
    entry = response.json()["entry"]
    assert set(entry) == {
        "entryId",
        "lemma",
        "senseLabel",
        "partOfSpeech",
        "glossPhrase",
        "status",
        "clip",
    }, f"C-017 entry fields differ: {sorted(entry)}"
    assert set(entry["clip"]) == {"url", "durationSeconds", "resolution", "hasAudio"}
    assert entry["entryId"] == "le_phone"
    assert entry["lemma"] == "phone"
    assert entry["senseLabel"] == "device"
    assert entry["partOfSpeech"] == "noun"
    assert entry["status"] == "active"


def test_an_unknown_entry_id_reads_as_not_found(library: httpx2.Client) -> None:
    # C-017 404: an unknown id is a not-found, with the frozen code.
    response = library.get("/internal/library/entries/le_missing", headers=INTERNAL)

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "entry_not_found"


def test_the_by_id_entry_read_requires_the_internal_audience(
    library: httpx2.Client,
) -> None:
    # C-017: internal service identity only; never reachable from the client.
    _store(
        library,
        _entry(
            "le_secret",
            lemma="secret",
            sense_label="hidden",
            part_of_speech="adjective",
        ),
    )

    response = library.get("/internal/library/entries/le_secret")

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "unauthorized"


# --- FEAT-006 across the generation loop (provider as a test double) ---------


def test_a_missing_word_is_generated_stored_and_then_served(
    loop_gateway: httpx2.Client,
    loop_library: httpx2.Client,
    loop_model_stub: httpx2.Client,
) -> None:
    # FEAT-006: a word absent from the library is generated; once stored it is
    # served to later readers without a new generation.
    loop_model_stub.post("/test/reset")

    created = _create(loop_gateway, "running", client_id="loop-run-1")
    assert created.status_code == 200, created.text
    assert created.json()["status"] == "generating"

    settled = _poll_until_settled(loop_gateway, created.json()["lookupId"])

    assert settled["status"] == "served"
    assert settled["senses"] and all(sense["clip"] is not None for sense in settled["senses"])
    entry_ids = {sense["entryId"] for sense in settled["senses"]}

    later = _create(loop_gateway, "runs", client_id="loop-run-2", subject="reader-2")
    assert later.status_code == 200, later.text
    assert later.json()["status"] == "served"
    assert {sense["entryId"] for sense in later.json()["senses"]} == entry_ids

    # The generated clip was written to the shared library as the pipeline's
    # write (C-009) does, keyed by lemma and sense.
    stored = _find(loop_library, lemma="run", sense_label="move_fast", part_of_speech="verb")
    entry = stored.json()["entry"]
    assert entry is not None
    assert entry["status"] == "active"
    assert entry["clip"]["resolution"] == "360p"


def test_one_generation_serves_two_readers_of_the_same_missing_word(
    loop_gateway: httpx2.Client,
    loop_model_stub: httpx2.Client,
) -> None:
    # FEAT-006 edge case: two readers look up the same missing word at once; a
    # single generation runs and both lookups are served from it.
    #
    # The model double holds the clip call so the first generation is provably in
    # flight when the second lookup arrives — the two lookups overlap by
    # construction, not by timing. The second lookup computes the same stable job
    # id for the word, is refused as a duplicate (C-003 409), and shares the one
    # generation, so the double records exactly one clip call.
    loop_model_stub.post("/test/reset")
    loop_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})
    try:
        first = _create(loop_gateway, "going", client_id="loop-go-a", subject="reader-a").json()
        assert first["status"] == "generating"
        # The first job has produced its gloss phrase, so it is inside the held
        # clip call and the shared library has no entry yet — a second lookup now
        # cannot be served instead of sharing.
        _wait_for_provider_call(loop_model_stub, name="phrase")

        second = _create(loop_gateway, "goes", client_id="loop-go-b", subject="reader-b").json()
        assert second["status"] == "generating"

        settled_first = _poll_until_settled(loop_gateway, first["lookupId"], subject="reader-a")
        settled_second = _poll_until_settled(loop_gateway, second["lookupId"], subject="reader-b")
        calls = loop_model_stub.get("/test/calls").json()
    finally:
        # Release the hold so a later test never inherits it.
        loop_model_stub.post("/test/reset")

    assert settled_first["status"] == "served"
    assert settled_second["status"] == "served"
    assert settled_first["senses"][0]["entryId"] == settled_second["senses"][0]["entryId"]

    assert calls["clip"] == 1, "a single generation runs for the shared word"


def test_a_phrase_selection_is_never_served_from_the_shared_library(
    loop_gateway: httpx2.Client,
    loop_library: httpx2.Client,
) -> None:
    # FEAT-006: the library holds word entries only. Even with an entry under a
    # phrase's key, a phrase selection is never read from the shared library.
    phrase = "over the moon"
    _store(
        loop_library,
        _entry(
            "le_phrase_guard",
            lemma=phrase,
            sense_label="phrase",
            part_of_speech="other",
            gloss="very happy",
        ),
    )

    body = _create(loop_gateway, phrase, client_id="loop-phrase-guard").json()

    assert body["kind"] == "phrase"
    assert body["status"] == "generating"
    assert body["senses"] == []


def test_a_generated_phrase_clip_is_not_written_to_the_shared_library(
    loop_gateway: httpx2.Client,
    loop_library: httpx2.Client,
    loop_model_stub: httpx2.Client,
) -> None:
    # FEAT-006 / FEAT-007: a phrase clip is generated for the requesting device
    # only; a successful phrase generation leaves no central library entry.
    loop_model_stub.post("/test/reset")
    phrase = "a walk in the park"

    created = _create(loop_gateway, phrase, client_id="loop-phrase-1").json()
    assert created["kind"] == "phrase"
    assert created["status"] == "generating"

    deadline = time.monotonic() + 10.0
    calls: dict[str, int] = {}
    while time.monotonic() < deadline:
        calls = loop_model_stub.get("/test/calls").json()
        if calls["clip"] >= 1:
            break
        time.sleep(0.1)
    assert calls["clip"] >= 1, "the phrase clip was generated"

    found = _find(loop_library, lemma=phrase, sense_label="phrase", part_of_speech="other")

    assert found.status_code == 200, found.text
    assert found.json() == {"entry": None}

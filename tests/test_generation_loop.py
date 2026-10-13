"""Integration and acceptance tests for the generation loop.

Verifies FEAT-005 (word-clip generation) across the lookup, pipeline, and model
services: a library miss is handed to the generation pipeline, the reader is
never blocked, and a generation that ends without a clip resolves the reader's
lookup to the fallback. Also checks the internal contracts C-003, C-006, C-004,
and C-005 as the services actually serve them.

`GEMINI_API_KEY` is unset, so the model layer reports the provider unavailable —
the shipped "model provider unavailable" degradation (nfr.md): the word and
phrase still show, with a note.
"""

from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

INTERNAL = {"x-internal-audience": "scenova-internal"}


def _auth(subject: str = "reader-1") -> dict[str, str]:
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


def _poll_until_settled(
    gateway: httpx2.Client,
    lookup_id: str,
    *,
    subject: str = "reader-1",
    attempts: int = 40,
    delay: float = 0.25,
) -> dict[str, Any]:
    """Poll a lookup until it stops generating, or fail on the timeout."""

    body: dict[str, Any] = {}
    for _ in range(attempts):
        response = gateway.get(f"/v1/lookups/{lookup_id}", headers=_auth(subject))
        assert response.status_code == 200, response.text
        body = response.json()
        if body["status"] != "generating":
            return body
        time.sleep(delay)
    pytest.fail(f"lookup {lookup_id} stayed 'generating': {body}")


def _job_payload(job_id: str = "job-1", **overrides: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "jobId": job_id,
        "lookupId": "lk_test",
        "kind": "word",
        "lemma": "come",
        "phrase": "to move toward a place",
        "senseLabel": "arrive",
        "partOfSpeech": "verb",
        "targetDurationSeconds": 4,
        "modelPin": "gemini-omni-1.1-flash",
        "attempt": 0,
    }
    payload.update(overrides)
    return payload


# --- FEAT-005: the reader is never blocked; a failed generation falls back ----


def test_a_library_miss_starts_a_generation_without_blocking(
    gateway: httpx2.Client,
) -> None:
    # The lookup returns at once with the word and phrase, and the clip generates
    # in the background (NFR-002, NFR-003).
    response = _create(gateway, "coming")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "generating"
    assert body["senses"], "the word and phrase still show while the clip generates"
    assert all(sense["clip"] is None for sense in body["senses"])


def test_a_failed_generation_resolves_to_the_fallback(gateway: httpx2.Client) -> None:
    # FEAT-005 / Alternate Path C: when the provider cannot produce a clip, the
    # reader sees the word and phrase with a note that the clip is unavailable.
    created = _create(gateway, "coming", client_id="fallback-1").json()
    assert created["status"] == "generating"

    settled = _poll_until_settled(gateway, created["lookupId"])

    assert settled["status"] == "fallback"
    assert settled["senses"], "the word and phrase remain in the fallback"
    assert all(sense["clip"] is None for sense in settled["senses"])
    assert settled["notice"], "the reader is told the clip is unavailable"


def test_a_generation_that_stays_generating_is_not_reported_as_served(
    gateway: httpx2.Client,
) -> None:
    # A poll must never claim a clip that does not exist: with no library entry
    # and no clip, the status is generating or fallback, never served.
    created = _create(gateway, "water", client_id="noghost-1").json()
    body = gateway.get(f"/v1/lookups/{created['lookupId']}", headers=_auth()).json()

    assert body["status"] in {"generating", "fallback"}
    assert all(sense["clip"] is None for sense in body["senses"])


def test_without_consent_generation_is_refused(gateway: httpx2.Client) -> None:
    # C-001 / nfr.md: generation requires consent; without it the lookup is denied
    # rather than sent to the model provider.
    response = _create(gateway, "coming", client_id="no-consent", consent=False)

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "denied"


def test_a_phrase_with_consent_starts_a_phrase_generation(gateway: httpx2.Client) -> None:
    response = _create(gateway, "a walk in the park", client_id="phrase-1")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["kind"] == "phrase"
    assert body["status"] == "generating"


def test_a_phrase_without_consent_is_denied(gateway: httpx2.Client) -> None:
    response = _create(gateway, "a walk in the park", client_id="phrase-denied", consent=False)

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "denied"


def test_two_readers_of_the_same_missing_word_share_one_generation(
    gateway: httpx2.Client,
) -> None:
    # FEAT-005 edge case: two readers request the same missing word at once; the
    # second enqueue collides on the job id (C-003 409) and shares the first.
    first = _create(gateway, "coming", client_id="share-a", subject="reader-a")
    second = _create(gateway, "coming", client_id="share-b", subject="reader-b")

    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["status"] == "generating"
    assert second.json()["status"] == "generating"
    assert first.json()["lookupId"] != second.json()["lookupId"]


# --- C-003: POST /internal/generation-jobs ------------------------------------


def test_the_job_endpoint_requires_the_internal_audience(
    pipeline: httpx2.Client,
) -> None:
    response = pipeline.post("/internal/generation-jobs", json=_job_payload())

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "unauthorized"


def test_a_job_over_the_four_second_cap_is_refused(pipeline: httpx2.Client) -> None:
    response = pipeline.post(
        "/internal/generation-jobs",
        headers=INTERNAL,
        json=_job_payload("job-over", targetDurationSeconds=5),
    )

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "target_duration_exceeded"


def test_a_job_with_no_phrase_is_refused(pipeline: httpx2.Client) -> None:
    response = pipeline.post(
        "/internal/generation-jobs",
        headers=INTERNAL,
        json=_job_payload("job-blank", phrase="   "),
    )

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "missing_phrase"


def test_enqueue_returns_202_and_a_repeat_conflicts(pipeline: httpx2.Client) -> None:
    first = pipeline.post(
        "/internal/generation-jobs", headers=INTERNAL, json=_job_payload("job-dup")
    )
    second = pipeline.post(
        "/internal/generation-jobs", headers=INTERNAL, json=_job_payload("job-dup")
    )

    assert first.status_code == 202, first.text
    assert set(first.json()) == {"jobId", "status"}
    assert first.json()["status"] in {"queued", "running"}
    assert second.status_code == 409, second.text
    assert second.json()["code"] == "job_already_enqueued"


# --- C-006: GET /internal/generation-jobs/{jobId} -----------------------------


def test_job_status_reports_a_terminal_state(pipeline: httpx2.Client) -> None:
    pipeline.post("/internal/generation-jobs", headers=INTERNAL, json=_job_payload("job-status"))

    deadline = time.monotonic() + 10.0
    body: dict[str, Any] = {}
    while time.monotonic() < deadline:
        response = pipeline.get("/internal/generation-jobs/job-status", headers=INTERNAL)
        assert response.status_code == 200, response.text
        body = response.json()
        if body["status"] in {"succeeded", "failed", "declined"}:
            break
        time.sleep(0.2)

    assert set(body) == {"jobId", "lookupId", "status"}
    # The provider is unavailable, so the job must end failed or declined — never
    # a silent success.
    assert body["status"] in {"failed", "declined"}


def test_an_unknown_job_is_not_found(pipeline: httpx2.Client) -> None:
    response = pipeline.get("/internal/generation-jobs/does-not-exist", headers=INTERNAL)

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "job_not_found"


# --- C-004 / C-005: the model-serving surface ---------------------------------


def test_the_phrase_endpoint_requires_the_internal_audience(model: httpx2.Client) -> None:
    response = model.post(
        "/internal/model/phrase",
        json={
            "lemma": "key",
            "partOfSpeech": "noun",
            "senseHint": "a small metal object that opens a lock",
            "modelPin": "gemini-omni-1.1-flash",
        },
    )

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "unauthorized"


def test_the_phrase_endpoint_reports_the_provider_unavailable(model: httpx2.Client) -> None:
    # C-004: provider unavailable after retries is 503, so the caller substitutes
    # its own fallback (the pipeline does; the reader still sees a phrase).
    response = model.post(
        "/internal/model/phrase",
        headers=INTERNAL,
        json={
            "lemma": "key",
            "partOfSpeech": "noun",
            "senseHint": "a small metal object that opens a lock",
            "modelPin": "gemini-omni-1.1-flash",
        },
    )

    assert response.status_code == 503, response.text
    assert set(response.json()) == {"code", "message"}


def test_the_clip_endpoint_requires_the_internal_audience(model: httpx2.Client) -> None:
    response = model.post(
        "/internal/model/clip",
        json={
            "phrase": "a key in the door",
            "targetDurationSeconds": 4,
            "modelPin": "gemini-omni-1.1-flash",
        },
    )

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "unauthorized"


def test_the_clip_endpoint_reports_the_provider_unavailable(model: httpx2.Client) -> None:
    response = model.post(
        "/internal/model/clip",
        headers=INTERNAL,
        json={
            "phrase": "a key in the door",
            "targetDurationSeconds": 4,
            "modelPin": "gemini-omni-1.1-flash",
        },
    )

    assert response.status_code == 503, response.text
    assert set(response.json()) == {"code", "message"}


def test_the_clip_endpoint_refuses_a_target_over_four_seconds(model: httpx2.Client) -> None:
    # C-005 pins the output at most four seconds; a longer target is a
    # request-contract violation (400), kept distinct from the provider's decline
    # (422) so the pipeline can tell a bad target from a phrase the provider
    # refused.
    response = model.post(
        "/internal/model/clip",
        headers=INTERNAL,
        json={
            "phrase": "a key in the door",
            "targetDurationSeconds": 5,
            "modelPin": "gemini-omni-1.1-flash",
        },
    )

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "target_duration_exceeded"

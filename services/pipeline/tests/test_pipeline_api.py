"""Internal API tests for the generation pipeline (C-003 status and shape mapping)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pipeline.app.api import create_app
from pipeline.app.config import Settings
from pipeline.app.service import GenerationService
from pipeline.tests.fakes import FailingQueue, rig

_INTERNAL = {"x-internal-audience": "scenova-internal"}


def _client(service: GenerationService, *, require_internal_auth: bool = True) -> TestClient:
    app = create_app(
        settings=Settings(require_internal_auth=require_internal_auth),
        service=service,
    )
    return TestClient(app)


def _payload(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "jobId": "job-1",
        "lookupId": "lk_1",
        "kind": "word",
        "lemma": "key",
        "phrase": "a key in the door",
        "senseLabel": "door_opener",
        "partOfSpeech": "noun",
        "targetDurationSeconds": 3.0,
        "modelPin": "gemini-omni-1.1-flash",
        "attempt": 1,
    }
    body.update(overrides)
    return body


def test_healthz() -> None:
    with _client(rig().service) as client:
        response = client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "pipeline"}


def test_the_endpoint_rejects_a_missing_audience() -> None:
    with _client(rig().service) as client:
        response = client.post("/internal/generation-jobs", json=_payload())

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_a_job_is_accepted_with_the_contract_shape() -> None:
    with _client(rig().service) as client:
        response = client.post("/internal/generation-jobs", json=_payload(), headers=_INTERNAL)

    assert response.status_code == 202
    assert response.json() == {"jobId": "job-1", "status": "queued"}


def test_a_blank_phrase_is_a_bad_request() -> None:
    with _client(rig().service) as client:
        response = client.post(
            "/internal/generation-jobs", json=_payload(phrase="  "), headers=_INTERNAL
        )

    assert response.status_code == 400
    assert response.json()["code"] == "missing_phrase"


def test_a_target_over_four_seconds_is_a_bad_request() -> None:
    with _client(rig().service) as client:
        response = client.post(
            "/internal/generation-jobs",
            json=_payload(targetDurationSeconds=5.0),
            headers=_INTERNAL,
        )

    assert response.status_code == 400
    assert response.json()["code"] == "target_duration_exceeded"


def test_a_malformed_body_is_a_bad_request() -> None:
    with _client(rig().service) as client:
        response = client.post(
            "/internal/generation-jobs",
            json={"kind": "word", "phrase": "a key"},
            headers=_INTERNAL,
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_part_of_speech_is_a_bad_request() -> None:
    with _client(rig().service) as client:
        response = client.post(
            "/internal/generation-jobs",
            json=_payload(partOfSpeech="pronoun"),
            headers=_INTERNAL,
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_repeated_job_id_conflicts() -> None:
    with _client(rig().service) as client:
        first = client.post("/internal/generation-jobs", json=_payload(), headers=_INTERNAL)
        second = client.post("/internal/generation-jobs", json=_payload(), headers=_INTERNAL)

    assert first.status_code == 202
    assert second.status_code == 409
    assert second.json()["code"] == "job_already_enqueued"


def test_an_unavailable_queue_is_a_service_unavailable() -> None:
    with _client(rig(queue=FailingQueue()).service) as client:
        response = client.post("/internal/generation-jobs", json=_payload(), headers=_INTERNAL)

    assert response.status_code == 503
    assert response.json()["code"] == "queue_unavailable"


@pytest.mark.asyncio
async def test_the_correlation_id_header_is_stored_on_the_job() -> None:
    # The enqueue's correlation id is kept so a generation event ties back to the
    # lookup that started it (`analytics.md` "Error & Performance Monitoring").
    test_rig = rig()
    with _client(test_rig.service) as client:
        response = client.post(
            "/internal/generation-jobs",
            json=_payload(),
            headers={**_INTERNAL, "x-correlation-id": "corr-1"},
        )

    assert response.status_code == 202
    job = await test_rig.queue.get("job-1")
    assert job is not None
    assert job.correlation_id == "corr-1"


def test_get_job_reports_the_contract_shape() -> None:
    with _client(rig().service) as client:
        client.post("/internal/generation-jobs", json=_payload(), headers=_INTERNAL)
        response = client.get("/internal/generation-jobs/job-1", headers=_INTERNAL)

    assert response.status_code == 200
    assert response.json() == {"jobId": "job-1", "lookupId": "lk_1", "status": "queued"}


def test_get_job_rejects_a_missing_audience() -> None:
    with _client(rig().service) as client:
        response = client.get("/internal/generation-jobs/job-1")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_get_an_unknown_job_is_not_found() -> None:
    with _client(rig().service) as client:
        response = client.get("/internal/generation-jobs/job-missing", headers=_INTERNAL)

    assert response.status_code == 404
    assert response.json()["code"] == "job_not_found"

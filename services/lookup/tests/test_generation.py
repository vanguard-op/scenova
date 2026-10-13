"""Client tests for the generation pipeline (C-003, C-006) and the shared job ids."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from lookup.app.generation import (
    GenerationAlreadyEnqueuedError,
    GenerationJob,
    GenerationJobStatus,
    GenerationUnavailableError,
    HttpGenerationClient,
    phrase_job_id,
    word_job_id,
)
from lookup.app.models import Kind, PartOfSpeech


def _job(job_id: str = "gen_abc") -> GenerationJob:
    return GenerationJob(
        job_id=job_id,
        lookup_id="lk_1",
        kind=Kind.WORD,
        lemma="come",
        phrase="to move toward or reach a place",
        sense_label="arrive",
        part_of_speech=PartOfSpeech.VERB,
        target_duration_seconds=4.0,
        model_pin="gemini-omni-1.1-flash",
    )


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpGenerationClient:
    return HttpGenerationClient(
        base_url="http://pipeline",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_a_queued_job_posts_the_contract_fields() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(202, json={"jobId": "gen_abc", "status": "queued"})

    client = _client(handler)
    await client.enqueue(_job())

    assert seen["path"] == "/internal/generation-jobs"
    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {
        "jobId": "gen_abc",
        "lookupId": "lk_1",
        "kind": "word",
        "lemma": "come",
        "phrase": "to move toward or reach a place",
        "senseLabel": "arrive",
        "partOfSpeech": "verb",
        "targetDurationSeconds": 4.0,
        "modelPin": "gemini-omni-1.1-flash",
        "attempt": 0,
    }
    await client.aclose()


@pytest.mark.asyncio
async def test_a_word_job_serialises_a_null_phrase() -> None:
    # A word job carries no phrase (C-003): the pipeline generates the gloss
    # phrase via C-004, so the field must go out as an explicit null.
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["body"] = json.loads(request.content)
        return httpx2.Response(202, json={"jobId": "gen_abc", "status": "queued"})

    client = _client(handler)
    await client.enqueue(
        GenerationJob(
            job_id="gen_abc",
            lookup_id="lk_1",
            kind=Kind.WORD,
            lemma="key",
            phrase=None,
            sense_label="door_opener",
            part_of_speech=PartOfSpeech.NOUN,
            target_duration_seconds=4.0,
            model_pin="gemini-omni-1.1-flash",
        )
    )

    body = seen["body"]
    assert isinstance(body, dict)
    assert body["phrase"] is None
    await client.aclose()


@pytest.mark.asyncio
async def test_an_already_enqueued_job_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(409, json={"code": "conflict"}))

    with pytest.raises(GenerationAlreadyEnqueuedError):
        await client.enqueue(_job())
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unavailable_pipeline_is_reported() -> None:
    client = _client(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    with pytest.raises(GenerationUnavailableError):
        await client.enqueue(_job())
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unexpected_status_is_treated_as_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(500, json={"code": "boom"}))

    with pytest.raises(GenerationUnavailableError):
        await client.enqueue(_job())
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_is_treated_as_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(GenerationUnavailableError):
        await client.enqueue(_job())
    await client.aclose()


@pytest.mark.asyncio
async def test_a_job_status_is_read_from_the_pipeline() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["audience"] = request.headers.get("x-internal-audience")
        return httpx2.Response(
            200,
            json={"jobId": "gen_abc", "lookupId": "lk_1", "status": "declined"},
        )

    client = _client(handler)
    status = await client.status("gen_abc")

    assert status is GenerationJobStatus.DECLINED
    assert seen["path"] == "/internal/generation-jobs/gen_abc"
    assert seen["audience"] == "scenova-internal"
    await client.aclose()


@pytest.mark.asyncio
async def test_a_job_the_pipeline_does_not_know_reports_none() -> None:
    client = _client(lambda _request: httpx2.Response(404, json={"code": "job_not_found"}))

    assert await client.status("gen_gone") is None
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_on_a_status_consult_is_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(GenerationUnavailableError):
        await client.status("gen_abc")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unexpected_status_code_on_a_consult_is_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    with pytest.raises(GenerationUnavailableError):
        await client.status("gen_abc")
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unreadable_status_body_is_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(200, json={"jobId": "gen_abc"}))

    with pytest.raises(GenerationUnavailableError):
        await client.status("gen_abc")
    await client.aclose()


def test_a_word_job_id_is_stable_and_keyed_by_the_sense() -> None:
    first = word_job_id("come", "arrive", PartOfSpeech.VERB)

    assert first == word_job_id("Come", "arrive", PartOfSpeech.VERB)
    assert first != word_job_id("come", "other_sense", PartOfSpeech.VERB)
    assert first != word_job_id("come", "arrive", PartOfSpeech.NOUN)
    # The word is personal data, so it never appears in the id.
    assert "come" not in first


def test_a_phrase_job_id_is_keyed_by_the_lookup() -> None:
    assert phrase_job_id("lk_1") != phrase_job_id("lk_2")
    assert phrase_job_id("lk_1") == phrase_job_id("lk_1")

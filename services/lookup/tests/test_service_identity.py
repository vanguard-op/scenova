"""The lookup service's identity at the edge of the services it calls.

The lookup service calls the pipeline, the shared library, and the entitlement
service. Each is internal only, so Cloud Run admits a call only from an
authenticated service identity (architecture.md "Component: API Gateway"; nfr.md
NFR-020). This proves every client mints an ID token for the service being called
— its own base URL, the audience Cloud Run binds the token to — and presents it
on the header Cloud Run reads.
"""

from __future__ import annotations

import httpx2
import pytest

from lookup.app import service_identity
from lookup.app.entitlement import HttpEntitlement
from lookup.app.generation import GenerationJob, HttpGenerationClient
from lookup.app.library import HttpLibrary
from lookup.app.models import Kind, PartOfSpeech
from lookup.app.service_identity import SERVERLESS_AUTHORIZATION_HEADER


class _Captured:
    """The headers a client sent, with a canned response to hand back."""

    def __init__(self, status_code: int, body: dict[str, object]) -> None:
        self.identity = ""
        self.internal_audience = ""
        self._status_code = status_code
        self._body = body

    def handle(self, request: httpx2.Request) -> httpx2.Response:
        self.identity = request.headers.get(SERVERLESS_AUTHORIZATION_HEADER, "")
        self.internal_audience = request.headers.get("x-internal-audience", "")
        return httpx2.Response(self._status_code, json=self._body)


def _enable_identity(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Turn the identity on as a deployed instance does, recording the audience."""

    audiences: list[str] = []

    def fetch(audience: str) -> str:
        audiences.append(audience)
        return "id-token"

    monkeypatch.setenv("K_SERVICE", "lookup")
    monkeypatch.setattr(service_identity, "_fetch_id_token", fetch)
    return audiences


@pytest.mark.asyncio
async def test_the_entitlement_client_mints_for_the_entitlement_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(
        200,
        {
            "allowed": True,
            "lookupsUsed": 1,
            "lookupsLimit": 20,
            "periodEnd": "2026-11-15T12:00:00+00:00",
        },
    )
    client = HttpEntitlement(
        base_url="https://entitlement.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.spend("reader-1", "lk_1")
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://entitlement.example"]


@pytest.mark.asyncio
async def test_the_generation_client_mints_for_the_pipeline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(202, {"status": "queued"})
    client = HttpGenerationClient(
        base_url="https://pipeline.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    job = GenerationJob(
        job_id="gen_1",
        lookup_id="lk_1",
        kind=Kind.WORD,
        lemma="key",
        phrase=None,
        sense_label="door_opener",
        part_of_speech=PartOfSpeech.NOUN,
        target_duration_seconds=4.0,
        model_pin="gemini-omni-1.1-flash",
    )
    try:
        await client.enqueue(job)
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://pipeline.example"]


@pytest.mark.asyncio
async def test_the_library_client_mints_for_the_shared_library(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(
        200,
        {
            "entry": {
                "entryId": "le_1",
                "glossPhrase": "a key",
                "status": "active",
                "clip": {
                    "url": "https://cdn.example/le_1.mp4",
                    "durationSeconds": 3.0,
                    "hasAudio": False,
                },
            }
        },
    )
    client = HttpLibrary(
        base_url="https://library.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.find("key", "door_opener", PartOfSpeech.NOUN)
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://library.example"]

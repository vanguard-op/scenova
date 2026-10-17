"""The feedback service's identity at the edge of the services it calls.

The feedback service calls the lookup service, the shared library, and the
pipeline. Each is internal only, so Cloud Run admits a call only from an
authenticated service identity (architecture.md "Component: API Gateway"; nfr.md
NFR-020). This proves every client mints an ID token for the service being called
— its own base URL, the audience Cloud Run binds the token to — and presents it
on the header Cloud Run reads.
"""

from __future__ import annotations

import httpx2
import pytest

from feedback.app import service_identity
from feedback.app.library import HttpLibrary
from feedback.app.lookups import HttpLookupDirectory
from feedback.app.regeneration import HttpRegenerationTrigger
from feedback.app.service_identity import SERVERLESS_AUTHORIZATION_HEADER


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

    monkeypatch.setenv("K_SERVICE", "feedback")
    monkeypatch.setattr(service_identity, "_fetch_id_token", fetch)
    return audiences


@pytest.mark.asyncio
async def test_the_lookup_client_mints_for_the_lookup_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(
        200,
        {"lookupId": "lk_1", "kind": "word", "status": "served", "senses": []},
    )
    client = HttpLookupDirectory(
        base_url="https://lookup.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.read("lk_1", "reader-1")
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://lookup.example"]


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
                "lemma": "key",
                "senseLabel": "door_opener",
                "partOfSpeech": "noun",
                "glossPhrase": "a key",
                "status": "active",
                "clip": {
                    "url": "https://cdn.example/le_1.mp4",
                    "durationSeconds": 3.0,
                    "resolution": "360p",
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
        await client.get_entry("le_1")
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://library.example"]


@pytest.mark.asyncio
async def test_the_regeneration_client_mints_for_the_pipeline(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(202, {"status": "queued"})
    client = HttpRegenerationTrigger(
        base_url="https://pipeline.example",
        internal_audience="scenova-internal",
        clip_model_pin="gemini-omni-1.1-flash",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.generate_candidate(
            entry_id="le_1",
            reader_lookup_id="lk_1",
            lemma="key",
            sense_label="door_opener",
            part_of_speech="noun",
            nonce="n-1",
        )
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://pipeline.example"]

"""The pipeline's identity at the edge of the services it calls.

The pipeline calls the model-serving layer, the shared library, and the
notification service. Each is internal only, so Cloud Run admits a call only from
an authenticated service identity (architecture.md "Component: API Gateway";
nfr.md NFR-020). This proves every client mints an ID token for the service being
called — its own base URL, the audience Cloud Run binds the token to — and
presents it on the header Cloud Run reads.
"""

from __future__ import annotations

import httpx2
import pytest

from pipeline.app import service_identity
from pipeline.app.clip_client import HttpClipClient
from pipeline.app.jobs import ClipAsset, LibraryEntry
from pipeline.app.library import HttpLibraryWriter
from pipeline.app.models import PartOfSpeech
from pipeline.app.notifier import HttpNotifier
from pipeline.app.phrase_client import HttpPhraseClient
from pipeline.app.service_identity import SERVERLESS_AUTHORIZATION_HEADER
from pipeline.tests.fakes import clip


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

    monkeypatch.setenv("K_SERVICE", "pipeline")
    monkeypatch.setattr(service_identity, "_fetch_id_token", fetch)
    return audiences


def _entry() -> LibraryEntry:
    return LibraryEntry(
        id="le_1",
        lemma="key",
        part_of_speech=PartOfSpeech.NOUN,
        sense_label="door_opener",
        gloss_phrase="a key",
        clip_asset_id="clip_1",
        status="active",
        source="generated",
        created_at="2026-10-13T00:00:00+00:00",
        updated_at="2026-10-13T00:00:00+00:00",
    )


def _asset() -> ClipAsset:
    return ClipAsset(
        id="clip_1",
        duration_seconds=3.0,
        resolution="360p",
        storage_key="clips/clip_1.mp4",
        url="https://cdn.example/clip_1.mp4",
        has_audio=False,
        synth_id_watermark=True,
        created_at="2026-10-13T00:00:00+00:00",
    )


@pytest.mark.asyncio
async def test_the_phrase_client_mints_for_the_model_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(200, {"phrase": "a key", "source": "generated", "bestGuess": False})
    client = HttpPhraseClient(
        base_url="https://model.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.generate(
            lemma="key",
            part_of_speech="noun",
            sense_hint="door_opener",
            model_pin="gemini-3.5-flash-lite",
        )
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://model.example"]


@pytest.mark.asyncio
async def test_the_clip_client_mints_for_the_model_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(
        201,
        {
            "clipId": "clip-1",
            "storageKey": "clips/clip-1.mp4",
            "url": "https://cdn.example/clip-1.mp4",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "hasAudio": False,
            "synthIdWatermark": True,
        },
    )
    client = HttpClipClient(
        base_url="https://model.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.generate(
            phrase="a key", target_duration_seconds=4.0, model_pin="gemini-omni-1.1-flash"
        )
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://model.example"]


@pytest.mark.asyncio
async def test_the_library_client_mints_for_the_shared_library(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(202, {"entryId": "le_1", "status": "active"})
    client = HttpLibraryWriter(
        base_url="https://library.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await client.store(_entry(), _asset())
    finally:
        await client.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://library.example"]


@pytest.mark.asyncio
async def test_the_notifier_mints_for_the_notification_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    audiences = _enable_identity(monkeypatch)
    captured = _Captured(202, {"queued": 1})
    notifier = HttpNotifier(
        base_url="https://notification.example",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(captured.handle),
    )
    try:
        await notifier.clip_ready(lookup_id="lk_1", job_id="job_1", clip=clip())
    finally:
        await notifier.aclose()

    assert captured.identity == "Bearer id-token"
    assert captured.internal_audience == "scenova-internal"
    assert audiences == ["https://notification.example"]

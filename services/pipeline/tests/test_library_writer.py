"""Client tests for the shared word-clip library write (FEAT-006)."""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from pipeline.app.jobs import ClipAsset, LibraryEntry
from pipeline.app.library import HttpLibraryWriter, LibraryUnavailableError
from pipeline.app.models import PartOfSpeech


def _entry(entry_id: str = "le_1") -> LibraryEntry:
    return LibraryEntry(
        id=entry_id,
        lemma="come",
        part_of_speech=PartOfSpeech.VERB,
        sense_label="arrive",
        gloss_phrase="to move toward a place",
        gloss_phrase_is_fallback=False,
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


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpLibraryWriter:
    return HttpLibraryWriter(
        base_url="http://library",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_a_word_clip_is_posted_as_the_library_expects() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(202, json={"entryId": "le_1", "status": "active"})

    client = _client(handler)
    await client.store(_entry(), _asset())

    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {
        "entry": {
            "id": "le_1",
            "lemma": "come",
            "partOfSpeech": "verb",
            "senseLabel": "arrive",
            "glossPhrase": "to move toward a place",
            "glossPhraseIsFallback": False,
            "clipAssetId": "clip_1",
            "status": "active",
            "source": "generated",
            "createdAt": "2026-10-13T00:00:00+00:00",
            "updatedAt": "2026-10-13T00:00:00+00:00",
        },
        "asset": {
            "id": "clip_1",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "storageKey": "clips/clip_1.mp4",
            "url": "https://cdn.example/clip_1.mp4",
            "hasAudio": False,
            "synthIdWatermark": True,
            "createdAt": "2026-10-13T00:00:00+00:00",
        },
    }
    await client.aclose()


@pytest.mark.asyncio
async def test_a_refused_write_is_reported_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    with pytest.raises(LibraryUnavailableError):
        await client.store(_entry(), _asset())
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_is_reported_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(LibraryUnavailableError):
        await client.store(_entry(), _asset())
    await client.aclose()

"""Client tests for the shared word-clip library read (FEAT-006)."""

from __future__ import annotations

from collections.abc import Callable

import httpx2
import pytest

from lookup.app.library import HttpLibrary, LibraryEntryStatus, LibraryUnavailableError
from lookup.app.models import PartOfSpeech


def _body(*, entry: object) -> dict[str, object]:
    return {"entry": entry}


def _entry(**overrides: object) -> dict[str, object]:
    body: dict[str, object] = {
        "entryId": "le_1",
        "status": "active",
        "glossPhrase": "to move toward a place",
        "clip": {
            "url": "https://cdn.example/le_1.mp4",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "hasAudio": False,
        },
    }
    body.update(overrides)
    return body


def _client(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpLibrary:
    return HttpLibrary(
        base_url="http://library",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_an_active_entry_is_mapped_from_the_response() -> None:
    client = _client(lambda _request: httpx2.Response(200, json=_body(entry=_entry())))

    entry = await client.find("come", "arrive", PartOfSpeech.VERB)

    assert entry is not None
    assert entry.id == "le_1"
    assert entry.status is LibraryEntryStatus.ACTIVE
    assert entry.gloss_phrase == "to move toward a place"
    assert entry.clip.url == "https://cdn.example/le_1.mp4"
    assert entry.clip.duration_seconds == 3.0
    assert entry.clip.has_audio is False
    await client.aclose()


@pytest.mark.asyncio
async def test_a_retired_entry_keeps_its_status() -> None:
    # The lookup must tell a retired entry from an absent one so it can seed a
    # replacement (FEAT-006).
    client = _client(
        lambda _request: httpx2.Response(200, json=_body(entry=_entry(status="retired")))
    )

    entry = await client.find("come", "arrive", PartOfSpeech.VERB)

    assert entry is not None
    assert entry.status is LibraryEntryStatus.RETIRED
    await client.aclose()


@pytest.mark.asyncio
async def test_a_miss_is_none() -> None:
    client = _client(lambda _request: httpx2.Response(200, json=_body(entry=None)))

    assert await client.find("come", "arrive", PartOfSpeech.VERB) is None
    await client.aclose()


@pytest.mark.asyncio
async def test_the_request_carries_the_audience_and_the_sense_key() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["params"] = dict(request.url.params)
        return httpx2.Response(200, json=_body(entry=None))

    client = _client(handler)
    await client.find("come", "arrive", PartOfSpeech.VERB)

    assert seen["audience"] == "scenova-internal"
    assert seen["params"] == {"lemma": "come", "senseLabel": "arrive", "partOfSpeech": "verb"}
    await client.aclose()


@pytest.mark.asyncio
async def test_an_error_status_is_reported_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(500, json={"code": "boom"}))

    with pytest.raises(LibraryUnavailableError):
        await client.find("come", "arrive", PartOfSpeech.VERB)
    await client.aclose()


@pytest.mark.asyncio
async def test_a_transport_failure_is_reported_unavailable() -> None:
    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    client = _client(handler)

    with pytest.raises(LibraryUnavailableError):
        await client.find("come", "arrive", PartOfSpeech.VERB)
    await client.aclose()


@pytest.mark.asyncio
async def test_an_unreadable_body_is_reported_unavailable() -> None:
    client = _client(lambda _request: httpx2.Response(200, json={"entry": {"entryId": "le_1"}}))

    with pytest.raises(LibraryUnavailableError):
        await client.find("come", "arrive", PartOfSpeech.VERB)
    await client.aclose()

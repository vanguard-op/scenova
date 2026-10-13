"""Tests for the clip-ready notice to the notification service (FEAT-008).

The pipeline reports a finished clip over the internal clip-ready ingest. The
notice carries the identifiers and the clip, never the word or phrase, and a
notification service that cannot take it never fails a job that already produced
a clip.
"""

from __future__ import annotations

import json
from collections.abc import Callable

import httpx2
import pytest

from pipeline.app.clip_client import ClipResult
from pipeline.app.notifier import HttpNotifier
from pipeline.tests.fakes import clip


def _notifier(handler: Callable[[httpx2.Request], httpx2.Response]) -> HttpNotifier:
    return HttpNotifier(
        base_url="http://notification",
        internal_audience="scenova-internal",
        transport=httpx2.MockTransport(handler),
    )


@pytest.mark.asyncio
async def test_the_notice_carries_the_clip_and_the_audience() -> None:
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["audience"] = request.headers.get("x-internal-audience")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(202, json={"queued": 1})

    notifier = _notifier(handler)
    await notifier.clip_ready(lookup_id="lk_1", job_id="job_1", clip=clip())

    assert seen["path"] == "/internal/clip-ready"
    assert seen["audience"] == "scenova-internal"
    assert seen["body"] == {
        "lookupId": "lk_1",
        "jobId": "job_1",
        "clip": {
            "clipId": "clip-1",
            "storageKey": "clips/clip-1.mp4",
            "url": "https://cdn.example/clip-1.mp4",
            "durationSeconds": 3.0,
            "resolution": "360p",
            "hasAudio": False,
            "synthIdWatermark": True,
        },
    }
    await notifier.aclose()


@pytest.mark.asyncio
async def test_the_notice_never_carries_the_word_or_phrase() -> None:
    # The reader's selection is theirs; it must not travel with a notice.
    seen: dict[str, object] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["body"] = request.content.decode()
        return httpx2.Response(202, json={"queued": 0})

    notifier = _notifier(handler)
    await notifier.clip_ready(lookup_id="lk_1", job_id="job_1", clip=clip())

    body = str(seen["body"]).casefold()
    assert "phrase" not in body
    assert "lemma" not in body
    assert "selection" not in body
    await notifier.aclose()


@pytest.mark.asyncio
async def test_an_unreachable_notification_service_does_not_raise() -> None:
    # The clip has already reached the reader, so a notice that cannot go out is
    # dropped rather than turned into a job failure.

    def handler(_request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused")

    notifier = _notifier(handler)

    await notifier.clip_ready(lookup_id="lk_1", job_id="job_1", clip=clip())
    await notifier.aclose()


@pytest.mark.asyncio
async def test_a_refused_notice_does_not_raise() -> None:
    notifier = _notifier(lambda _request: httpx2.Response(503, json={"code": "unavailable"}))

    await notifier.clip_ready(lookup_id="lk_1", job_id="job_1", clip=clip())
    await notifier.aclose()


@pytest.mark.asyncio
async def test_a_clip_is_reported_for_a_lookup_without_the_word() -> None:
    # A finished clip is reported for any job that produced one, word or phrase.
    reported: list[str] = []

    def handler(_request: httpx2.Request) -> httpx2.Response:
        reported.append("sent")
        return httpx2.Response(202, json={"queued": 0})

    notifier = _notifier(handler)
    await notifier.clip_ready(
        lookup_id="lk_2",
        job_id="job_2",
        clip=ClipResult(
            clip_id="clip-2",
            storage_key="clips/clip-2.mp4",
            url="https://cdn.example/clip-2.mp4",
            duration_seconds=4.0,
            resolution="360p",
            has_audio=True,
            synth_id_watermark=True,
        ),
    )

    assert reported == ["sent"]
    await notifier.aclose()

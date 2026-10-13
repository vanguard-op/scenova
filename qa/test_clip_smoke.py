"""The live word-clip smoke through the shipped path (C-005, FEAT-005).

The integration harness exercises the pipeline against a local model double and
the unit suites pin the clip service and router with a fake provider; both are
green even if the live integration with the pinned video model is broken. This
smoke runs exactly one clip through the shipped C-005 surface against the pinned
model and asserts what the contract and FEAT-005 promise: a 201 whose body
carries the C-005 fields, a 360p clip of three to four seconds that carries the
provider's watermark and audio, and an encoded MP4 that matches.

It is marked `model`: it needs the pinned-model credential or it cannot run, and
it fails rather than skips when the credential is absent, so a release cannot
read a never-run smoke as green (nfr.md, "Measurement & Verification"). The run
itself lives in `qa/clip_smoke.py`, which is also the `python -m qa.clip_smoke`
entry point that writes the smoke report.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from app.config import Settings, load_settings

from qa.clip_smoke import (
    INTERNAL_HEADER,
    ClipSmoke,
    RecordingClipStore,
    build_smoke_app,
    contract_failures,
    default_smoke_item,
    post_clip,
    run_clip_smoke,
)

pytestmark = [pytest.mark.acceptance, pytest.mark.model]


def _live_settings() -> Settings:
    settings = load_settings()
    if not settings.gemini_api_key:
        pytest.fail(
            "the live clip smoke needs the pinned-model credential (GEMINI_API_KEY); it "
            "is not set, so one clip cannot be put through the shipped path. A "
            "credential is a judged-run input (nfr.md, Model Quality & Cost)."
        )
    return settings


@pytest.fixture(scope="module")
def smoke() -> Iterator[ClipSmoke]:
    """One live clip through the shipped path, shared by the assertions below."""

    settings = _live_settings()
    phrase = str(default_smoke_item().get("phrase", ""))
    yield run_clip_smoke(phrase, target_duration_seconds=4.0, settings=settings)


def test_one_clip_flows_through_the_shipped_path(smoke: ClipSmoke) -> None:
    # The point of the smoke: the request the generation pipeline sends (C-005)
    # comes back as a produced clip, not a 4xx/5xx — and exactly one clip was
    # made and stored.
    assert smoke.status_code == 201, dict(smoke.body)
    assert len(smoke.stored_keys) == 1
    assert smoke.body.get("storageKey") in smoke.stored_keys


def test_the_clip_meets_the_feature_output_contract(smoke: ClipSmoke) -> None:
    # FEAT-005's output contract and its success criterion: 360p, three to four
    # seconds, the provider's watermark, and an audio track the reader unmutes.
    assert smoke.body.get("resolution") == "360p"
    assert smoke.body.get("synthIdWatermark") is True
    assert smoke.body.get("hasAudio") is True
    reported = smoke.reported_duration_seconds
    assert reported is not None
    assert 3.0 <= reported <= 4.0, f"the clip is {reported}s, not three to four"


def test_the_returned_media_is_the_clip_the_contract_promises(smoke: ClipSmoke) -> None:
    # The served durationSeconds is the value the path chose; the media is the
    # evidence. The clip must be a real MP4 whose video track is 360p and whose
    # encoded length is the served length within a frame of encoder rounding.
    assert smoke.clip_bytes, "no clip bytes were stored"
    assert smoke.media.brand, "the returned bytes are not an MP4"
    assert smoke.media.has_video_track
    assert (smoke.media.width, smoke.media.height) == (640, 360)
    assert smoke.media.has_audio_track
    measured = smoke.media.container_duration_seconds
    assert measured is not None
    assert 2.95 <= measured <= 4.05, f"the encoded clip runs {measured}s, not three to four"


def test_every_contract_check_passes(smoke: ClipSmoke) -> None:
    # The single judged verdict a report reads; each miss names expected-vs-actual.
    assert contract_failures(smoke) == ()


def test_the_clip_endpoint_refuses_a_caller_without_the_internal_audience() -> None:
    # C-005 auth: the endpoint is internal-only, so the provider is never called.
    settings = load_settings()
    store = RecordingClipStore(settings)
    app = build_smoke_app(settings, store)
    response = post_clip(
        app,
        {
            "phrase": "a key in the door",
            "targetDurationSeconds": 4,
            "modelPin": settings.clip_model_pin,
        },
        {},
    )
    assert response.status_code == 401
    assert store.writes == []


def test_the_clip_endpoint_refuses_a_target_over_four_seconds() -> None:
    # C-005 request contract: a target over the four-second cap is a 400, and the
    # provider is never called.
    settings = load_settings()
    store = RecordingClipStore(settings)
    app = build_smoke_app(settings, store)
    response = post_clip(
        app,
        {
            "phrase": "a key in the door",
            "targetDurationSeconds": 5,
            "modelPin": settings.clip_model_pin,
        },
        {INTERNAL_HEADER: settings.internal_audience},
    )
    assert response.status_code == 400
    assert response.json()["code"] == "target_duration_exceeded"
    assert store.writes == []

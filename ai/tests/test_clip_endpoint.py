"""Contract conformance for POST /internal/model/clip (C-005)."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from app.provider import ProviderRefusal, ProviderTimeout, ProviderUnavailable
from helpers import (
    AUTH_HEADERS,
    CDN_BASE,
    CLIP_BYTES,
    FakeClipModel,
    FakeClipStore,
    clip_payload,
    make_app,
)

PATH = "/internal/model/clip"


async def post(
    model: FakeClipModel,
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    store: FakeClipStore | None = None,
) -> httpx.Response:
    app = make_app(FakeClipModel([]), clip_model=model, clip_store=store)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://model") as client:
        return await client.post(
            PATH,
            json=payload if payload is not None else clip_payload(),
            headers=headers if headers is not None else AUTH_HEADERS,
        )


@pytest.mark.asyncio
async def test_generated_clip_matches_the_output_contract() -> None:
    store = FakeClipStore()

    response = await post(FakeClipModel([CLIP_BYTES]), store=store)

    assert response.status_code == 201
    body = response.json()
    assert body["clipId"]
    assert body["storageKey"] == f"clips/{body['clipId']}.mp4"
    assert body["url"] == f"{CDN_BASE}/{body['storageKey']}"
    assert body["durationSeconds"] == 4.0
    assert body["resolution"] == "360p"
    assert body["hasAudio"] is False
    assert body["synthIdWatermark"] is True
    assert store.puts == [(body["storageKey"], CLIP_BYTES, "video/mp4")]


@pytest.mark.asyncio
async def test_a_phrase_selection_is_generated_from_the_phrase_itself() -> None:
    model = FakeClipModel([CLIP_BYTES])

    response = await post(model, payload=clip_payload(phrase="break the ice"))

    assert response.status_code == 201
    # A phrase job sends the reader's selection straight to the clip step (no
    # gloss step), and the shipped direction depicts its meaning, not the
    # literal words (FEAT-007; NFR-053).
    assert "break the ice" in model.calls[0]["user"]
    assert "meaning" in model.calls[0]["system"]


@pytest.mark.asyncio
async def test_short_target_rounds_up_to_the_next_second() -> None:
    response = await post(
        FakeClipModel([CLIP_BYTES]),
        payload=clip_payload(targetDurationSeconds=1.5),
    )

    assert response.status_code == 201
    assert response.json()["durationSeconds"] == 2.0


@pytest.mark.asyncio
async def test_refusal_is_422_and_stores_nothing() -> None:
    store = FakeClipStore()

    response = await post(FakeClipModel([ProviderRefusal("declined")]), store=store)

    assert response.status_code == 422
    assert response.json()["code"] == "provider_declined"
    assert store.puts == []


@pytest.mark.asyncio
async def test_timeout_is_504_and_stores_nothing() -> None:
    store = FakeClipStore()

    response = await post(FakeClipModel([ProviderTimeout("slow")]), store=store)

    assert response.status_code == 504
    assert response.json()["code"] == "provider_timeout"
    assert store.puts == []


@pytest.mark.asyncio
async def test_provider_unavailable_is_503() -> None:
    response = await post(FakeClipModel([ProviderUnavailable("down")]))

    assert response.status_code == 503
    assert response.json()["code"] == "provider_unavailable"


@pytest.mark.asyncio
async def test_storage_failure_is_503() -> None:
    response = await post(FakeClipModel([CLIP_BYTES]), store=FakeClipStore(fail=True))

    assert response.status_code == 503
    assert response.json()["code"] == "storage_unavailable"


@pytest.mark.asyncio
async def test_missing_audience_is_401() -> None:
    response = await post(FakeClipModel([CLIP_BYTES]), headers={})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


@pytest.mark.asyncio
async def test_wrong_audience_is_401() -> None:
    response = await post(
        FakeClipModel([CLIP_BYTES]),
        headers={"x-internal-audience": "someone-else"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_target_over_four_seconds_is_a_400_not_a_decline() -> None:
    model = FakeClipModel([CLIP_BYTES])
    store = FakeClipStore()

    response = await post(
        model,
        payload=clip_payload(targetDurationSeconds=5),
        store=store,
    )

    # A bad target is a request-contract violation, distinct from the provider's
    # decline (422): the pipeline can tell the two apart by status and code.
    assert response.status_code == 400
    assert response.json()["code"] == "target_duration_exceeded"
    assert response.json()["message"]
    # Nothing is generated or stored for a rejected target.
    assert model.calls == []
    assert store.puts == []


@pytest.mark.asyncio
async def test_target_at_the_four_second_cap_is_accepted() -> None:
    response = await post(
        FakeClipModel([CLIP_BYTES]),
        payload=clip_payload(targetDurationSeconds=4),
    )

    assert response.status_code == 201
    assert response.json()["durationSeconds"] == 4.0


@pytest.mark.asyncio
async def test_missing_phrase_is_rejected() -> None:
    payload = clip_payload()
    payload.pop("phrase")

    response = await post(FakeClipModel([CLIP_BYTES]), payload=payload)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_blank_phrase_is_rejected() -> None:
    response = await post(FakeClipModel([CLIP_BYTES]), payload=clip_payload(phrase="   "))

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_unknown_field_is_rejected() -> None:
    response = await post(
        FakeClipModel([CLIP_BYTES]),
        payload=clip_payload(unexpected="x"),
    )

    assert response.status_code == 422

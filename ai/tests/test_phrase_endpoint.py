"""Contract conformance for POST /internal/model/phrase (C-004)."""

from __future__ import annotations

from typing import Any

import httpx
import pytest
from app.provider import ProviderRefusal, ProviderUnavailable
from helpers import AUTH_HEADERS, FakePhraseModel, make_app, phrase_payload

PATH = "/internal/model/phrase"


async def post(
    model: FakePhraseModel,
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> httpx.Response:
    app = make_app(model)
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://model") as client:
        return await client.post(
            PATH,
            json=payload if payload is not None else phrase_payload(),
            headers=headers if headers is not None else AUTH_HEADERS,
        )


@pytest.mark.asyncio
async def test_generated_phrase_matches_the_output_contract() -> None:
    response = await post(FakePhraseModel(["a key in the door"]))

    assert response.status_code == 200
    assert response.json() == {
        "phrase": "a key in the door",
        "source": "generated",
        "bestGuess": False,
    }


@pytest.mark.asyncio
async def test_refusal_returns_a_fallback_with_200() -> None:
    response = await post(FakePhraseModel([ProviderRefusal("declined")]))

    assert response.status_code == 200
    assert response.json() == {
        "phrase": "a key",
        "source": "fallback",
        "bestGuess": True,
    }


@pytest.mark.asyncio
async def test_provider_unavailable_is_503() -> None:
    response = await post(FakePhraseModel([ProviderUnavailable("down")]))

    assert response.status_code == 503
    assert response.json()["code"] == "provider_unavailable"


@pytest.mark.asyncio
async def test_missing_audience_is_401() -> None:
    response = await post(FakePhraseModel(["a key in the door"]), headers={})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


@pytest.mark.asyncio
async def test_wrong_audience_is_401() -> None:
    response = await post(
        FakePhraseModel(["a key in the door"]),
        headers={"x-internal-audience": "someone-else"},
    )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_missing_required_field_is_rejected() -> None:
    payload = phrase_payload()
    payload.pop("partOfSpeech")

    response = await post(FakePhraseModel(["a key in the door"]), payload=payload)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_unknown_field_is_rejected() -> None:
    response = await post(
        FakePhraseModel(["a key in the door"]),
        payload=phrase_payload(unexpected="x"),
    )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_healthz_is_served() -> None:
    app = make_app(FakePhraseModel([]))
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://model") as client:
        response = await client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "service": "model"}

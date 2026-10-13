"""Test double for the external model-provider surface (C-004, C-005).

The generation-loop QA stack replaces the model-serving service with this double
so a clip can be produced without reaching the real model provider. It speaks the
same internal endpoints and response shapes the pipeline's clients (C-004, C-005)
require; it is test support, never a shipped service.

It also exposes two test-only routes under `/test` so an integration test can
observe how many provider calls were made — the evidence for "one generation runs
for a shared word" (FEAT-006 edge case).
"""

from __future__ import annotations

from typing import Annotated
from uuid import uuid4

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

_INTERNAL_AUDIENCE = "scenova-internal"

app = FastAPI(title="Scenova Model Provider (test double)", version="1.0.0")

_calls: dict[str, int] = {"phrase": 0, "clip": 0}


class PhraseRequest(BaseModel):
    lemma: str | None = None
    partOfSpeech: str
    senseHint: str
    modelPin: str


class ClipRequest(BaseModel):
    phrase: str
    targetDurationSeconds: float
    modelPin: str


def _require_internal(audience: str | None) -> None:
    if audience != _INTERNAL_AUDIENCE:
        raise HTTPException(status_code=401, detail="internal callers only")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "service": "model-stub"}


@app.post("/internal/model/phrase")
def generate_phrase(
    payload: PhraseRequest,
    x_internal_audience: Annotated[str | None, Header()] = None,
) -> dict[str, object]:
    _require_internal(x_internal_audience)
    _calls["phrase"] += 1
    # A short, common gloss phrase derived from the sense hint the pipeline sent.
    phrase = payload.senseHint.strip() or "a word used in context"
    return {"phrase": phrase, "source": "generated", "bestGuess": False}


@app.post("/internal/model/clip", status_code=201, response_model=None)
def generate_clip(
    payload: ClipRequest,
    x_internal_audience: Annotated[str | None, Header()] = None,
) -> dict[str, object] | JSONResponse:
    _require_internal(x_internal_audience)
    if payload.targetDurationSeconds > 4:
        return JSONResponse(
            status_code=400,
            content={
                "code": "target_duration_exceeded",
                "message": "A clip target over four seconds is outside the cap.",
            },
        )
    _calls["clip"] += 1
    clip_id = f"clip_{uuid4().hex}"
    return {
        "clipId": clip_id,
        "storageKey": f"clips/{clip_id}.mp4",
        "url": f"https://cdn.example/{clip_id}.mp4",
        "durationSeconds": 3.0,
        "resolution": "360p",
        "hasAudio": False,
        "synthIdWatermark": True,
    }


@app.get("/test/calls")
def provider_calls() -> dict[str, int]:
    """The provider calls made since the last reset (test-only)."""

    return dict(_calls)


@app.post("/test/reset")
def reset_calls() -> dict[str, int]:
    """Zero the provider-call counters (test-only)."""

    _calls["phrase"] = 0
    _calls["clip"] = 0
    return dict(_calls)

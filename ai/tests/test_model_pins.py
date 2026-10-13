"""Each generation step carries its own pinned model (FEAT-004, FEAT-005).

The gloss phrase is a text capability pinned to the text model and measured on
NFR-050; the clip is a video capability pinned to the video model and measured on
NFR-051/NFR-053 (architecture "Model Version & Fallback"). These guard the two
pins against collapsing back into one, and the phrase path against defaulting to
the video model.
"""

from __future__ import annotations

import pytest
from app.clip.service import ClipRequest
from app.config import CLIP_MODEL_PIN, PHRASE_MODEL_PIN, load_settings
from app.phrase.service import PhraseRequest
from helpers import (
    CLIP_BYTES,
    FakeClipModel,
    FakePhraseModel,
    make_clip_service,
    make_service,
)


def test_the_two_pins_are_the_documented_models() -> None:
    # The pins the quality bar was measured against (NFR-050, NFR-051, NFR-053).
    assert PHRASE_MODEL_PIN == "gemini-3.5-flash-lite"
    assert CLIP_MODEL_PIN == "gemini-omni-1.1-flash"
    assert PHRASE_MODEL_PIN != CLIP_MODEL_PIN


def test_settings_default_each_step_to_its_own_pin() -> None:
    settings = load_settings()

    assert settings.phrase_model_pin == PHRASE_MODEL_PIN
    assert settings.clip_model_pin == CLIP_MODEL_PIN


@pytest.mark.asyncio
async def test_the_phrase_path_defaults_to_the_text_model() -> None:
    model = FakePhraseModel(["a key in the door"])

    await make_service(model).generate(
        PhraseRequest(lemma="key", part_of_speech="noun", sense_hint="opens a lock", model_pin="")
    )

    _system, _user, pin = model.calls[0]
    assert pin == PHRASE_MODEL_PIN


@pytest.mark.asyncio
async def test_the_clip_path_defaults_to_the_video_model() -> None:
    model = FakeClipModel([CLIP_BYTES])

    await make_clip_service(model).generate(
        ClipRequest(phrase="a key in the door", target_duration_seconds=4.0, model_pin="")
    )

    assert model.calls[0]["model_pin"] == CLIP_MODEL_PIN

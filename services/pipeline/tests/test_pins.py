"""The pinned models the generation path depends on (schema "ModelPin", FEAT-005).

Covers the two capabilities' pins, their modality and evaluation state, and that
the versions follow configuration rather than being hardcoded at the call site.
"""

from __future__ import annotations

from pipeline.app.config import Settings
from pipeline.app.pins import ModelPins


def test_the_two_pins_cover_the_phrase_and_the_clip() -> None:
    pins = ModelPins.from_settings(Settings())

    assert pins.phrase.modality == "text"
    assert pins.phrase.version == "gemini-3.5-flash-lite"
    assert pins.clip.modality == "video"
    assert pins.clip.version == "gemini-omni-1.1-flash"


def test_a_pin_the_pipeline_has_not_seen_evaluated_is_unevaluated() -> None:
    # The quality-bar run owns the verdict; the pipeline never assumes passing.
    pins = ModelPins.from_settings(Settings())

    assert pins.phrase.quality_status == "unevaluated"
    assert pins.clip.quality_status == "unevaluated"
    assert pins.phrase.last_evaluated_at is None


def test_the_pins_follow_configuration() -> None:
    pins = ModelPins.from_settings(Settings(phrase_model_pin="text-v2"))

    assert pins.phrase.model_id == "text-v2"
    assert pins.phrase.version == "text-v2"

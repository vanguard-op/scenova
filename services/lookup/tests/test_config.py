"""Configuration tests: the clip model pin is read from its own key."""

from __future__ import annotations

from lookup.app.config import CLIP_MODEL_PIN, Settings


def test_the_clip_pin_defaults_to_the_pinned_video_model() -> None:
    assert Settings.from_env({}).clip_model_pin == "gemini-omni-1.1-flash"
    assert CLIP_MODEL_PIN == "gemini-omni-1.1-flash"


def test_the_clip_pin_is_read_from_its_own_key() -> None:
    settings = Settings.from_env({"CLIP_MODEL_PIN": "gemini-omni-2.0-flash"})

    assert settings.clip_model_pin == "gemini-omni-2.0-flash"


def test_the_clip_pin_ignores_the_shared_model_key() -> None:
    # The generic key is not the clip pin's home; reading it here would couple
    # the clip to whichever model that key names (D-018).
    settings = Settings.from_env({"GEMINI_MODEL": "gemini-3.5-flash-lite"})

    assert settings.clip_model_pin == "gemini-omni-1.1-flash"

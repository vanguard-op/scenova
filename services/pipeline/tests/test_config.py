"""Configuration tests: the phrase-clip kill switch is read from its own flag."""

from __future__ import annotations

from pipeline.app.config import Settings


def test_the_phrase_clip_flag_defaults_on() -> None:
    # A missing variable must not silently disable the feature; the rollout value
    # is supplied per environment (release.md "Rollout Phases & Feature Flags").
    assert Settings.from_env({}).enable_phrase_clip is True


def test_the_phrase_clip_flag_is_read_from_its_env_key() -> None:
    assert Settings.from_env({"FLAG_ENABLE_PHRASE_CLIP": "false"}).enable_phrase_clip is False
    assert Settings.from_env({"FLAG_ENABLE_PHRASE_CLIP": "true"}).enable_phrase_clip is True

"""Fallback phrase template (FEAT-004)."""

from __future__ import annotations

from app.phrase.fallback import fallback_phrase


def test_uses_the_lemma_when_present() -> None:
    assert fallback_phrase(lemma="key", sense_hint="a small metal object") == "a key"


def test_falls_back_to_the_sense_hint_head_when_lemma_is_absent() -> None:
    assert fallback_phrase(lemma=None, sense_hint="ice on a lake") == "a ice"


def test_uses_a_neutral_word_when_nothing_is_available() -> None:
    assert fallback_phrase(lemma=None, sense_hint="") == "a thing"


def test_ignores_a_blank_lemma() -> None:
    assert fallback_phrase(lemma="   ", sense_hint="door") == "a door"

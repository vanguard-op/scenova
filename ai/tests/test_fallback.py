"""Fallback phrase template (FEAT-004)."""

from __future__ import annotations

from app.phrase.fallback import fallback_phrase


def test_uses_the_lemma_when_present() -> None:
    assert fallback_phrase(lemma="key", sense_hint="a small metal object") == "a key"


def test_uses_an_before_a_vowel_sound() -> None:
    assert fallback_phrase(lemma="ice", sense_hint="frozen water") == "an ice"


def test_uses_an_before_a_silent_h() -> None:
    assert fallback_phrase(lemma="hour", sense_hint="sixty minutes") == "an hour"


def test_uses_a_before_a_u_that_sounds_like_yoo() -> None:
    assert fallback_phrase(lemma="university", sense_hint="a place of study") == "a university"


def test_falls_back_to_the_sense_hint_head_when_lemma_is_absent() -> None:
    assert fallback_phrase(lemma=None, sense_hint="ice on a lake") == "an ice"


def test_uses_a_neutral_word_when_nothing_is_available() -> None:
    assert fallback_phrase(lemma=None, sense_hint="") == "a thing"


def test_ignores_a_blank_lemma() -> None:
    assert fallback_phrase(lemma="   ", sense_hint="door") == "a door"


def test_uses_the_bare_word_for_a_capitalised_proper_noun() -> None:
    assert fallback_phrase(lemma="Paris", sense_hint="the capital of France") == "Paris"


def test_uses_the_bare_word_for_a_proper_noun_tag() -> None:
    phrase = fallback_phrase(
        lemma="paris",
        sense_hint="the capital of France",
        part_of_speech="proper noun",
    )

    assert phrase == "paris"


def test_uses_the_bare_word_for_a_non_english_word() -> None:
    assert fallback_phrase(lemma="café", sense_hint="a place to drink") == "café"

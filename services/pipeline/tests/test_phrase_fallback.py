"""Fallback gloss phrase tests for the pipeline's C-004 503 path (FEAT-004).

Covers the template the pipeline substitutes when the model layer is
unreachable: the article matches the word's initial sound, and a proper noun or
a non-English word takes no article.
"""

from __future__ import annotations

from pipeline.app.phrase_fallback import fallback_phrase


def test_a_consonant_word_takes_a() -> None:
    assert fallback_phrase(lemma="key", sense_hint="door_opener") == "a key"


def test_a_vowel_sound_word_takes_an() -> None:
    assert fallback_phrase(lemma="ice", sense_hint="frozen_water") == "an ice"


def test_a_silent_h_word_takes_an() -> None:
    assert fallback_phrase(lemma="hour", sense_hint="sixty_minutes") == "an hour"


def test_a_yoo_sound_word_takes_a() -> None:
    assert fallback_phrase(lemma="university", sense_hint="a_place_of_study") == "a university"


def test_a_proper_noun_takes_no_article() -> None:
    assert fallback_phrase(lemma="Paris", sense_hint="the capital of France") == "Paris"


def test_a_non_english_word_takes_no_article() -> None:
    assert fallback_phrase(lemma="café", sense_hint="a place to drink") == "café"


def test_the_sense_hint_supplies_the_word_when_the_lemma_is_absent() -> None:
    assert fallback_phrase(lemma=None, sense_hint="ice on a lake") == "an ice"


def test_an_empty_input_still_yields_a_phrase() -> None:
    assert fallback_phrase(lemma=None, sense_hint="") == "a thing"

"""Guardrail behaviour for a candidate gloss phrase (FEAT-004)."""

from __future__ import annotations

import pytest
from app.data import load_common_words
from app.phrase.guardrails import GuardrailResult, is_usable, normalize_phrase

COMMON = frozenset(
    {"a", "an", "the", "key", "door", "old", "in", "on", "idea", "grew", "well", "known"}
)


def test_the_bundled_vocabulary_covers_everyday_words() -> None:
    words = load_common_words()

    assert {"key", "door", "spoon", "ladder", "cage", "fence"} <= words


def check(
    text: str,
    *,
    lemma: str | None = "key",
    max_words: int = 6,
    max_chars: int = 120,
) -> GuardrailResult:
    return is_usable(
        text,
        lemma=lemma,
        common_words=COMMON,
        max_words=max_words,
        max_chars=max_chars,
    )


def test_accepts_the_documented_example() -> None:
    result = check("a key in the door")

    assert result.ok is True
    assert result.phrase == "a key in the door"
    assert result.reason is None


def test_strips_wrapping_quotes_and_collapses_whitespace() -> None:
    result = check('  "a key   in the door."  ')

    assert result.ok is True
    assert result.phrase == "a key in the door."


def test_rejects_seven_words() -> None:
    result = check("a key in the door on the wall")

    assert result.ok is False
    assert result.reason == "too many words"


def test_accepts_six_words() -> None:
    assert check("a key in the old door").ok is True


def test_rejects_empty_and_whitespace() -> None:
    assert check("").reason == "empty"
    assert check("   ").reason == "empty"


def test_rejects_an_uncommon_word() -> None:
    result = check("a key in the perambulator")

    assert result.ok is False
    assert result.reason is not None
    assert "perambulator" in result.reason


def test_allows_the_word_being_glossed_even_if_uncommon() -> None:
    result = check("a perambulator in the door", lemma="perambulator")

    assert result.ok is True


def test_rejects_more_than_one_sentence() -> None:
    result = check("a key. a door.")

    assert result.ok is False
    assert result.reason == "more than one sentence"


def test_rejects_multiple_lines() -> None:
    result = check("a key in the door\n")

    assert result.ok is False
    assert result.reason == "not a single phrase"


def test_rejects_over_the_character_cap() -> None:
    assert check("a key in the door", max_chars=5).reason == "too long"


def test_hyphenated_words_are_checked_part_by_part() -> None:
    assert check("a well-known door").ok is True


def test_accepts_a_common_inflection_of_a_known_base() -> None:
    words = frozenset({"he", "the", "climb", "ladder"})

    result = is_usable(
        "he climbs the ladder",
        lemma="ladder",
        common_words=words,
        max_words=6,
        max_chars=120,
    )

    assert result.ok is True


def test_accepts_a_past_tense_of_a_known_base() -> None:
    words = frozenset({"she", "walk", "home"})

    result = is_usable(
        "she walked home",
        lemma="walk",
        common_words=words,
        max_words=6,
        max_chars=120,
    )

    assert result.ok is True


def test_rejects_a_word_with_no_common_base() -> None:
    assert check("a key in the perambulator").reason is not None


def test_normalize_phrase_is_stable() -> None:
    assert normalize_phrase("  a   key \n") == "a key"


@pytest.mark.parametrize("text", ["Key in the door", "A KEY IN THE DOOR"])
def test_matching_is_case_insensitive(text: str) -> None:
    assert check(text).ok is True

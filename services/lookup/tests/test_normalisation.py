"""Selection normalisation tests (FEAT-003 edge cases)."""

from __future__ import annotations

from lookup.app.normalisation import (
    MAX_PHRASE_WORDS,
    strip_edge_punctuation,
    tokenise,
)


def test_attached_punctuation_is_stripped() -> None:
    assert strip_edge_punctuation("word,") == "word"
    assert strip_edge_punctuation("(word)") == "word"
    assert strip_edge_punctuation("\u201cword\u201d") == "word"
    assert strip_edge_punctuation("word!?") == "word"


def test_internal_marks_are_kept() -> None:
    assert strip_edge_punctuation("don't") == "don't"
    assert strip_edge_punctuation("well-known") == "well-known"


def test_tokenise_drops_whitespace_and_punctuation_only_parts() -> None:
    assert tokenise("  Hello,   world!  ") == ["Hello", "world"]
    assert tokenise("...") == []
    assert tokenise("   ") == []


def test_phrase_limit_is_six_words() -> None:
    assert MAX_PHRASE_WORDS == 6

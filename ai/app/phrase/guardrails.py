"""Guardrails for a generated gloss phrase (FEAT-004).

A phrase is usable when it is a single phrase or simple sentence of fewer than
seven words, built only from common words. The word being glossed is allowed
through even if it is itself uncommon, because the phrase exists to show that
word in use; every other word must be in the common vocabulary.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Words, allowing internal apostrophes and hyphens ("don't", "well-known").
_TOKEN_RE = re.compile(r"[a-z][a-z'-]*")
_SENTENCE_SPLIT_RE = re.compile(r"[.!?]+")
_WORD_PART_RE = re.compile(r"[-']")
_SURROUNDING_QUOTES = "\"'\u201c\u201d\u2018\u2019"


@dataclass(frozen=True, slots=True)
class GuardrailResult:
    """Outcome of checking one candidate phrase."""

    ok: bool
    phrase: str
    reason: str | None = None


def normalize_phrase(text: str) -> str:
    """Collapse whitespace and strip wrapping quotation marks."""

    collapsed = " ".join(text.split())
    return collapsed.strip().strip(_SURROUNDING_QUOTES).strip()


def _tokens(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


def _allowed_words(lemma: str | None) -> set[str]:
    return set(_tokens(lemma)) if lemma else set()


def _unknown_words(phrase: str, *, allowed: set[str], common_words: frozenset[str]) -> list[str]:
    unknown: list[str] = []
    for token in _tokens(phrase):
        if token in allowed or token in common_words:
            continue
        parts = [part for part in _WORD_PART_RE.split(token) if part]
        if parts and all(part in allowed or part in common_words for part in parts):
            continue
        unknown.append(token)
    return unknown


def is_usable(
    raw: str,
    *,
    lemma: str | None,
    common_words: frozenset[str],
    max_words: int,
    max_chars: int,
) -> GuardrailResult:
    """Check a candidate phrase against the output contract."""

    def fail(reason: str, phrase: str = "") -> GuardrailResult:
        return GuardrailResult(ok=False, phrase=phrase, reason=reason)

    if not raw or not raw.strip():
        return fail("empty")
    if "\n" in raw or "\r" in raw:
        return fail("not a single phrase")

    phrase = normalize_phrase(raw)
    if not phrase:
        return fail("empty")
    if len(phrase) > max_chars:
        return fail("too long", phrase)

    sentences = [part for part in _SENTENCE_SPLIT_RE.split(phrase) if part.strip()]
    if len(sentences) > 1:
        return fail("more than one sentence", phrase)

    words = phrase.split()
    if not words:
        return fail("empty")
    if len(words) > max_words:
        return fail("too many words", phrase)

    unknown = _unknown_words(
        phrase,
        allowed=_allowed_words(lemma),
        common_words=common_words,
    )
    if unknown:
        return fail(f"uncommon words: {', '.join(unknown)}", phrase)

    return GuardrailResult(ok=True, phrase=phrase)

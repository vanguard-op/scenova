"""Fallback gloss phrase (FEAT-004).

On refusal, timeout, or an unusable phrase, Scenova substitutes a fixed template
of the form "a <word>" and marks the meaning as a best guess, so the reader
still sees a phrase.
"""

from __future__ import annotations

import re

_TOKEN_RE = re.compile(r"[a-z][a-z'-]*")
_EMPTY_FALLBACK = "thing"


def _fallback_word(*, lemma: str | None, sense_hint: str) -> str:
    candidate = (lemma or "").strip()
    if candidate:
        return candidate
    tokens: list[str] = _TOKEN_RE.findall(sense_hint.lower())
    if tokens:
        return tokens[0]
    return _EMPTY_FALLBACK


def fallback_phrase(*, lemma: str | None, sense_hint: str) -> str:
    """Return the fixed fallback phrase for a word or sense."""

    return f"a {_fallback_word(lemma=lemma, sense_hint=sense_hint)}"

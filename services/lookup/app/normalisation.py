"""Selection normalisation for word and phrase lookups (FEAT-003).

A selection is tokenised by whitespace; punctuation attached to a token is
stripped before lookup while internal marks (apostrophes, hyphens) are kept, so
"coming," and "well-known" behave as expected. One token is a word lookup; two
to six tokens are a short phrase routed to the phrase path; more than six is
over the phrase limit.
"""

from __future__ import annotations

import unicodedata

# A short phrase is two to six words (FEAT-003; settled in the phase-1 decisions).
MAX_PHRASE_WORDS = 6


def strip_edge_punctuation(token: str) -> str:
    """Remove leading and trailing punctuation from a token, keeping the rest."""

    start = 0
    end = len(token)
    while start < end and _is_punctuation(token[start]):
        start += 1
    while end > start and _is_punctuation(token[end - 1]):
        end -= 1
    return token[start:end]


def tokenise(selection: str) -> list[str]:
    """Split a selection into tokens, dropping empty and punctuation-only parts."""

    tokens: list[str] = []
    for piece in selection.split():
        token = strip_edge_punctuation(piece)
        if token:
            tokens.append(token)
    return tokens


def _is_punctuation(character: str) -> bool:
    return unicodedata.category(character).startswith("P")

"""Fallback gloss phrase for the C-004 503 path (FEAT-004).

The model layer substitutes this template itself on a refusal, a timeout, or an
unusable phrase, and it arrives as a normal C-004 result with `source=fallback`.
When the model layer cannot be reached after its own retries the phrase endpoint
answers 503, and C-004 leaves the substitution to its caller: the generation
pipeline. This module is that substitution, so a phrase step that never reached
the model still hands the clip step a grammatical noun phrase.

It is deliberately the same template the model layer uses — the word with the
indefinite article that matches its initial sound ("a key", "an ice"), or the
bare word where no article applies, as with a proper noun or a non-English word —
because the reader must see the same phrase whichever side had to substitute it.
"""

from __future__ import annotations

import re

_TOKEN_RE = re.compile(r"[a-z][a-z'-]*")
_ENGLISH_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]*\Z")
_EMPTY_FALLBACK = "thing"

_VOWEL_LETTERS = frozenset("aeiou")

# Words that start with a vowel letter but a consonant sound take "a": the
# "yoo" families ("unicorn", "united"), "eu"/"ewe", and "one"/"once". Each
# prefix is long enough to leave the near neighbours that really do open with a
# vowel sound ("usher", "onerous", "unable") on the article path.
_CONSONANT_SOUND_PREFIXES = (
    "eu",
    "ewe",
    "ubiq",
    "ukul",
    "unan",
    "unic",
    "unif",
    "unil",
    "unim",
    "unio",
    "unip",
    "uniq",
    "unis",
    "unit",
    "univ",
    "unix",
    "uran",
    "urin",
    "use",
    "user",
    "usual",
    "usur",
    "util",
    "utens",
    "utop",
)
_CONSONANT_SOUND_WORDS = frozenset({"one", "once", "one's", "oneself"})

# Words that start with a consonant letter but a vowel sound take "an": the
# silent "h" families.
_VOWEL_SOUND_PREFIXES = ("heir", "honest", "honor", "honour", "hour")


def fallback_phrase(*, lemma: str | None, sense_hint: str, part_of_speech: str = "") -> str:
    """Return the fixed fallback phrase for a word or sense."""

    word = _fallback_word(lemma=lemma, sense_hint=sense_hint)
    if not _is_english_word(word) or _is_proper_noun(word, part_of_speech):
        return word
    article = "an" if _takes_an(word) else "a"
    return f"{article} {word}"


def _fallback_word(*, lemma: str | None, sense_hint: str) -> str:
    candidate = (lemma or "").strip()
    if candidate:
        return candidate
    tokens: list[str] = _TOKEN_RE.findall(sense_hint.lower())
    if tokens:
        return tokens[0]
    return _EMPTY_FALLBACK


def _is_english_word(word: str) -> bool:
    """A word with characters outside the English alphabet takes no article."""

    return bool(_ENGLISH_WORD_RE.fullmatch(word))


def _is_proper_noun(word: str, part_of_speech: str) -> bool:
    """Detect a proper noun from its part-of-speech tag or its capitalisation.

    A normalised lemma is lowercase, so a leading capital is the signal the
    pipeline leaves when the tagger reports a plain noun.
    """

    compact = re.sub(r"[^a-z]", "", part_of_speech.lower())
    if compact == "prop" or "propn" in compact or "proper" in compact:
        return True
    return word[:1].isupper()


def _takes_an(word: str) -> bool:
    """Whether the word's initial sound is a vowel, so it takes "an"."""

    lowered = word.lower()
    if lowered.startswith(_VOWEL_SOUND_PREFIXES):
        return True
    if lowered in _CONSONANT_SOUND_WORDS or lowered.startswith(_CONSONANT_SOUND_PREFIXES):
        return False
    return lowered[:1] in _VOWEL_LETTERS

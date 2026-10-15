"""Locale handling for the reader's account (C-020).

The account holds the reader's preferred locale for the selection-action label
(schema "Account"). Preferences lets the reader choose a language even when the
label has no translation yet — it falls back to English (FEAT-012) — so the
check here is that the value names a real language, not that a translation
exists. A well-formed BCP-47 tag whose primary subtag is a real ISO 639-1
language is accepted; anything else is the contract's "unknown locale" and is
refused.

The accepted form is canonicalised before it is stored: the language lowercased,
a two-letter region uppercased, a four-letter script title-cased.
"""

from __future__ import annotations

import re

# The ISO 639-1 language codes. A primary subtag outside this set is not a
# language the product can name, so it is an unknown locale.
_ISO_639_1 = frozenset(
    (
        "aa",
        "ab",
        "ae",
        "af",
        "ak",
        "am",
        "an",
        "ar",
        "as",
        "av",
        "ay",
        "az",
        "ba",
        "be",
        "bg",
        "bh",
        "bi",
        "bm",
        "bn",
        "bo",
        "br",
        "bs",
        "ca",
        "ce",
        "ch",
        "co",
        "cr",
        "cs",
        "cu",
        "cv",
        "cy",
        "da",
        "de",
        "dv",
        "dz",
        "ee",
        "el",
        "en",
        "eo",
        "es",
        "et",
        "eu",
        "fa",
        "ff",
        "fi",
        "fj",
        "fo",
        "fr",
        "fy",
        "ga",
        "gd",
        "gl",
        "gn",
        "gu",
        "gv",
        "ha",
        "he",
        "hi",
        "ho",
        "hr",
        "ht",
        "hu",
        "hy",
        "hz",
        "ia",
        "id",
        "ie",
        "ig",
        "ii",
        "ik",
        "io",
        "is",
        "it",
        "iu",
        "ja",
        "jv",
        "ka",
        "kg",
        "ki",
        "kj",
        "kk",
        "kl",
        "km",
        "kn",
        "ko",
        "kr",
        "ks",
        "ku",
        "kv",
        "kw",
        "ky",
        "la",
        "lb",
        "lg",
        "li",
        "ln",
        "lo",
        "lt",
        "lu",
        "lv",
        "mg",
        "mh",
        "mi",
        "mk",
        "ml",
        "mn",
        "mr",
        "ms",
        "mt",
        "my",
        "na",
        "nb",
        "nd",
        "ne",
        "ng",
        "nl",
        "nn",
        "no",
        "nr",
        "nv",
        "ny",
        "oc",
        "oj",
        "om",
        "or",
        "os",
        "pa",
        "pi",
        "pl",
        "ps",
        "pt",
        "qu",
        "rm",
        "rn",
        "ro",
        "ru",
        "rw",
        "sa",
        "sc",
        "sd",
        "se",
        "sg",
        "si",
        "sk",
        "sl",
        "sm",
        "sn",
        "so",
        "sq",
        "sr",
        "ss",
        "st",
        "su",
        "sv",
        "sw",
        "ta",
        "te",
        "tg",
        "th",
        "ti",
        "tk",
        "tl",
        "tn",
        "to",
        "tr",
        "ts",
        "tt",
        "tw",
        "ty",
        "ug",
        "uk",
        "ur",
        "uz",
        "ve",
        "vi",
        "vo",
        "wa",
        "wo",
        "xh",
        "yi",
        "yo",
        "za",
        "zh",
        "zu",
    )
)

# language ["-" subtag]* — the subtag length bounds keep a malformed value out.
_LOCALE_PATTERN = re.compile(r"^(?P<language>[A-Za-z]{2,3})(?P<subtags>(?:-[A-Za-z0-9]{1,8})*)$")


def normalise_locale(value: str) -> str | None:
    """The canonical form of a locale, or None when it is unknown.

    None is the contract's 400: a value that is not a well-formed BCP-47 tag, or
    whose primary subtag is not an ISO 639-1 language.
    """

    match = _LOCALE_PATTERN.fullmatch(value.strip())
    if match is None:
        return None
    language = match.group("language").lower()
    if len(language) != 2 or language not in _ISO_639_1:
        return None
    return language + _normalise_subtags(match.group("subtags"))


def _normalise_subtags(subtags: str) -> str:
    if not subtags:
        return ""
    parts = []
    for raw in subtags.lstrip("-").split("-"):
        if len(raw) == 2:
            parts.append(raw.upper())
        elif len(raw) == 4:
            parts.append(raw.title())
        else:
            parts.append(raw.lower())
    return "-" + "-".join(parts)

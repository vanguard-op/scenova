"""Tests for locale canonicalisation (C-020)."""

from __future__ import annotations

import pytest

from entitlement.app.locales import normalise_locale


@pytest.mark.parametrize(
    ("given", "expected"),
    [
        ("en", "en"),
        ("EN", "en"),
        ("en-us", "en-US"),
        ("en-GB", "en-GB"),
        ("es-419", "es-419"),
        ("pt-br", "pt-BR"),
        ("zh-hans", "zh-Hans"),
        ("zh-Hans-CN", "zh-Hans-CN"),
        ("  fr  ", "fr"),
    ],
)
def test_a_real_language_is_canonicalised(given: str, expected: str) -> None:
    assert normalise_locale(given) == expected


@pytest.mark.parametrize(
    "given",
    ["", "   ", "e", "english", "zz", "not-a-locale", "en--US", "en-US-", "-en", "en US"],
)
def test_a_value_that_is_not_a_language_is_unknown(given: str) -> None:
    assert normalise_locale(given) is None

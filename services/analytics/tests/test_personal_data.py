"""Personal-data scan tests (`analytics.md` "Analytics Data Governance").

A taxonomy property is an identifier, a count, or an enum token. The scan must
refuse the reader's word or phrase, an email or a phone number, and any prose,
while letting every value the taxonomy actually uses through.
"""

from __future__ import annotations

import pytest

from analytics.app.personal_data import MAX_VALUE_LENGTH, personal_data_reason

_CLEAN = [
    ("source", "android_action"),
    ("kind", "word"),
    ("entry_id", "le_0123456789abcdef0123456789abcdef"),
    ("model_version", "gemini-omni-1.1-flash"),
    ("resolution", "360p"),
    ("duration_ms", 1200),
    ("cost_units", 1.0),
    ("action_enabled", True),
    ("consent", False),
    ("plan", "free"),
    ("product_id", "com.scenova.pro.monthly"),
    ("value", None),
]

_DIRTY = [
    ("email", "reader@example.com", "names personal data"),
    ("word", "coming", "names personal data"),
    ("gloss_phrase", "to arrive", "names personal data"),
    ("reason", "reader@example.com", "looks like an email address"),
    ("reason", "+15551234567", "looks like a phone number"),
    ("reason", "the reader typed this", "carries free text"),
    ("reason", "x" * (MAX_VALUE_LENGTH + 1), "carries free text"),
    ("value", {"nested": "object"}, "carries a structured value"),
]


@pytest.mark.parametrize(("key", "value"), _CLEAN)
def test_taxonomy_values_are_clean(key: str, value: object) -> None:
    assert personal_data_reason(key, value) is None


@pytest.mark.parametrize(("key", "value", "expected"), _DIRTY)
def test_personal_data_is_refused(key: str, value: object, expected: str) -> None:
    reason = personal_data_reason(key, value)
    assert reason is not None
    assert expected in reason

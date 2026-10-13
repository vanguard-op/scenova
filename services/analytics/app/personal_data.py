"""The personal-data scan for event properties (`analytics.md` "Analytics Data
Governance": "No personal data in properties").

Two layers guard the store. The taxonomy allowlist keeps a client from inventing
a property key, so the reader's word, phrase, email, or name has nowhere to go.
This scan guards the values: a value that names personal data, looks like an
email address or a phone number, or reads as free text is refused. Every
taxonomy property is an identifier, a count, or an enum token, so a prose value
is by definition off-taxonomy.
"""

from __future__ import annotations

import re

# Property names that would carry personal data if a client ever sent them. No
# taxonomy key collides with one, so this only ever fires on drift.
_PERSONAL_KEYS: frozenset[str] = frozenset(
    {
        "email",
        "e-mail",
        "name",
        "full_name",
        "first_name",
        "last_name",
        "word",
        "phrase",
        "selection",
        "gloss",
        "gloss_phrase",
        "text",
        "raw",
        "raw_selection",
        "query",
        "content",
        "message",
        "phone",
        "address",
        "token",
        "authorization",
        "password",
    }
)

_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
# A value that is exactly an E.164 number, so a genuine phone number is caught
# without flagging an id that merely contains digits.
_E164_PHONE = re.compile(r"\+[1-9]\d{6,14}\Z")

# The longest a taxonomy property may be. Every one is a short identifier or an
# enum token; a longer string is free text.
MAX_VALUE_LENGTH = 64


def personal_data_reason(key: str, value: object) -> str | None:
    """Why a property would carry personal data, or None when it is clean.

    The reason is phrased for the operator's log and the client's message; the
    value itself is never echoed back.
    """

    if key.strip().lower() in _PERSONAL_KEYS:
        return f"the property '{key}' names personal data"
    if value is None or isinstance(value, bool | int | float):
        return None
    if not isinstance(value, str):
        return f"the property '{key}' carries a structured value"
    if len(value) > MAX_VALUE_LENGTH:
        return f"the property '{key}' carries free text"
    if _EMAIL.search(value):
        return f"the property '{key}' looks like an email address"
    if _E164_PHONE.match(value):
        return f"the property '{key}' looks like a phone number"
    if any(character.isspace() for character in value):
        return f"the property '{key}' carries free text"
    return None

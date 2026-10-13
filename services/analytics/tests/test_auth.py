"""Token verification tests (C-007 auth).

The subject the verifier returns is the pseudonymous `user_id` on every stored
event, so an unverified or subject-less token must never yield one.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import pytest

from analytics.app.auth import DevTokenVerifier, FirebaseTokenVerifier
from analytics.app.errors import UnauthorizedError


@pytest.mark.asyncio
async def test_the_dev_verifier_reads_the_subject() -> None:
    subject = await DevTokenVerifier().verify("Bearer dev:reader-7")
    assert subject.id == "reader-7"


@pytest.mark.asyncio
@pytest.mark.parametrize("header", [None, "", "Bearer", "Basic dev:reader-7", "Bearer nope"])
async def test_the_dev_verifier_rejects_a_bad_header(header: str | None) -> None:
    with pytest.raises(UnauthorizedError):
        await DevTokenVerifier().verify(header)


@pytest.mark.asyncio
async def test_the_firebase_verifier_reads_the_subject_claim() -> None:
    async def decode(_token: str) -> Mapping[str, Any]:
        return {"sub": "reader-3"}

    subject = await FirebaseTokenVerifier("scenova-test", decoder=decode).verify("Bearer a.b.c")
    assert subject.id == "reader-3"


@pytest.mark.asyncio
async def test_the_firebase_verifier_rejects_a_token_without_a_subject() -> None:
    async def decode(_token: str) -> Mapping[str, Any]:
        return {"aud": "scenova-test"}

    with pytest.raises(UnauthorizedError):
        await FirebaseTokenVerifier("scenova-test", decoder=decode).verify("Bearer a.b.c")

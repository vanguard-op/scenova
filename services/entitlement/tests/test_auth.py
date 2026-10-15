"""Tests for token verification (C-018, C-020 auth)."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from typing import Any

import pytest

from entitlement.app.auth import DevTokenVerifier, FirebaseTokenVerifier, Subject
from entitlement.app.errors import UnauthorizedError


@pytest.mark.asyncio
async def test_a_dev_token_is_a_signed_in_reader() -> None:
    subject = await DevTokenVerifier().verify("Bearer dev:reader-1")

    assert subject == Subject(id="reader-1")


@pytest.mark.asyncio
async def test_a_dev_anonymous_token_is_not_signed_in() -> None:
    subject = await DevTokenVerifier().verify("Bearer dev-anon:device-9")

    assert subject.id == "device-9"
    assert subject.is_anonymous is True


@pytest.mark.asyncio
@pytest.mark.parametrize("header", [None, "", "Bearer", "Basic dev:reader-1", "Bearer nope"])
async def test_a_bad_authorization_header_is_refused(header: str | None) -> None:
    with pytest.raises(UnauthorizedError):
        await DevTokenVerifier().verify(header)


@pytest.mark.asyncio
async def test_a_firebase_token_is_read_for_its_subject_email_and_provider() -> None:
    verifier = FirebaseTokenVerifier("proj", decoder=_decoder({"sub": "u1", "email": "a@b.c"}))
    subject = await verifier.verify("Bearer token")

    assert subject == Subject(id="u1", email="a@b.c", is_anonymous=False)


@pytest.mark.asyncio
async def test_a_firebase_anonymous_token_is_recognised() -> None:
    claims = {"sub": "u1", "firebase": {"sign_in_provider": "anonymous"}}
    verifier = FirebaseTokenVerifier("proj", decoder=_decoder(claims))
    subject = await verifier.verify("Bearer token")

    assert subject.is_anonymous is True
    assert subject.email is None


@pytest.mark.asyncio
async def test_a_firebase_token_without_a_subject_is_refused() -> None:
    verifier = FirebaseTokenVerifier("proj", decoder=_decoder({"email": "a@b.c"}))

    with pytest.raises(UnauthorizedError):
        await verifier.verify("Bearer token")


@pytest.mark.asyncio
async def test_an_unverifiable_firebase_token_is_refused() -> None:
    async def explode(_token: str) -> Mapping[str, Any]:
        raise ValueError("bad signature")

    with pytest.raises(UnauthorizedError):
        await FirebaseTokenVerifier("proj", decoder=explode).verify("Bearer token")


def _decoder(claims: Mapping[str, Any]) -> Callable[[str], Awaitable[Mapping[str, Any]]]:
    async def decode(_token: str) -> Mapping[str, Any]:
        return claims

    return decode

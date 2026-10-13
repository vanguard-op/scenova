"""Token verification tests."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

import pytest

from gateway.app.auth import (
    DevTokenVerifier,
    FirebaseTokenVerifier,
    Subject,
    build_token_verifier,
)
from gateway.app.config import Settings
from gateway.app.errors import UnauthorizedError


@pytest.mark.asyncio
async def test_dev_verifier_accepts_an_explicit_subject() -> None:
    subject = await DevTokenVerifier().verify("Bearer dev:reader-1")

    assert subject == Subject(id="reader-1")


@pytest.mark.asyncio
async def test_dev_verifier_accepts_a_firebase_shaped_token() -> None:
    subject = await DevTokenVerifier().verify("Bearer aaa.bbb.ccc")

    assert subject.id == "aaa.bbb.ccc"


@pytest.mark.asyncio
@pytest.mark.parametrize("header", [None, "", "Bearer", "Bearer dev:", "Basic abc", "nonsense"])
async def test_dev_verifier_rejects_bad_headers(header: str | None) -> None:
    with pytest.raises(UnauthorizedError):
        await DevTokenVerifier().verify(header)


@pytest.mark.asyncio
async def test_firebase_verifier_reads_the_subject_claim() -> None:
    async def decode(token: str) -> Mapping[str, Any]:
        return {"sub": "firebase-uid", "aud": "scenova-dev"}

    subject = await FirebaseTokenVerifier("scenova-dev", decoder=decode).verify("Bearer x.y.z")

    assert subject.id == "firebase-uid"


@pytest.mark.asyncio
async def test_firebase_verifier_rejects_a_token_without_a_subject() -> None:
    async def decode(token: str) -> Mapping[str, Any]:
        return {"aud": "scenova-dev"}

    with pytest.raises(UnauthorizedError):
        await FirebaseTokenVerifier("scenova-dev", decoder=decode).verify("Bearer x.y.z")


@pytest.mark.asyncio
async def test_firebase_verifier_wraps_a_decoder_failure() -> None:
    async def decode(token: str) -> Mapping[str, Any]:
        raise ValueError("bad signature")

    with pytest.raises(UnauthorizedError):
        await FirebaseTokenVerifier("scenova-dev", decoder=decode).verify("Bearer x.y.z")


def test_build_token_verifier_defaults_to_dev() -> None:
    assert isinstance(build_token_verifier(Settings(auth_mode="dev")), DevTokenVerifier)


def test_build_token_verifier_requires_a_project_for_firebase() -> None:
    with pytest.raises(ValueError):
        build_token_verifier(Settings(auth_mode="firebase", firebase_project_id=None))

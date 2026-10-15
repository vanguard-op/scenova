"""Token verification tests."""

from __future__ import annotations

import time
from collections.abc import Iterator, Mapping
from datetime import UTC, datetime, timedelta
from typing import Any

import jwt
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

from gateway.app import auth
from gateway.app.auth import (
    DevTokenVerifier,
    FirebaseTokenVerifier,
    Subject,
    _public_key_pem,
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
    assert subject.is_anonymous is False


@pytest.mark.asyncio
async def test_dev_verifier_marks_a_signed_out_reader_anonymous() -> None:
    subject = await DevTokenVerifier().verify("Bearer dev-anon:device-9")

    assert subject == Subject(id="device-9", is_anonymous=True)


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
    assert subject.is_anonymous is False


@pytest.mark.asyncio
async def test_firebase_verifier_recognises_an_anonymous_token() -> None:
    async def decode(token: str) -> Mapping[str, Any]:
        return {"sub": "anon-uid", "firebase": {"sign_in_provider": "anonymous"}}

    subject = await FirebaseTokenVerifier("scenova-dev", decoder=decode).verify("Bearer x.y.z")

    assert subject.is_anonymous is True


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


def _signing_certificate() -> tuple[str, rsa.RSAPrivateKey]:
    """A self-signed RSA certificate, shaped like a Firebase signing certificate."""

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "securetoken.test")])
    now = datetime.now(UTC)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=30))
        .sign(private_key, hashes.SHA256())
    )
    return certificate.public_bytes(serialization.Encoding.PEM).decode("utf-8"), private_key


def _private_key_pem(private_key: rsa.RSAPrivateKey) -> str:
    return private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode("utf-8")


@pytest.fixture(autouse=True)
def _reset_signing_key_cache() -> Iterator[None]:
    auth._signing_keys.clear()
    auth._signing_keys_expire_at = 0.0
    yield
    auth._signing_keys.clear()
    auth._signing_keys_expire_at = 0.0


def test_public_key_pem_extracts_the_key_from_a_certificate() -> None:
    certificate_pem, private_key = _signing_certificate()

    extracted = _public_key_pem(certificate_pem)

    assert extracted.encode("utf-8") == private_key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )


@pytest.mark.asyncio
async def test_firebase_verifier_verifies_a_token_signed_by_a_certificate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    certificate_pem, private_key = _signing_certificate()
    key_id = "test-kid"

    async def fetch_certificates() -> Mapping[str, str]:
        return {key_id: certificate_pem}

    monkeypatch.setattr(auth, "_fetch_certificates", fetch_certificates)

    issued_at = int(time.time())
    token = jwt.encode(
        {
            "sub": "anonymous-uid",
            "aud": "scenova-hq",
            "iss": "https://securetoken.google.com/scenova-hq",
            "iat": issued_at,
            "exp": issued_at + 3600,
        },
        _private_key_pem(private_key),
        algorithm="RS256",
        headers={"kid": key_id},
    )

    subject = await FirebaseTokenVerifier("scenova-hq").verify(f"Bearer {token}")

    assert subject.id == "anonymous-uid"

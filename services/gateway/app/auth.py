"""Token verification for the client contracts.

Authentication is enforced at the gateway (D-011): before accounts ship the
caller presents an anonymous Firebase ID token, upgraded to the reader's account
at sign-in. `DevTokenVerifier` is the local seam for the pre-account path;
`FirebaseTokenVerifier` verifies real ID tokens against the project's signing
certificates.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any, Protocol

import httpx2
import jwt
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from .config import Settings
from .errors import UnauthorizedError

_FIREBASE_CERTS_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/" "securetoken@system.gserviceaccount.com"
)
_CERT_CACHE_TTL_SECONDS = 3600.0


@dataclass(frozen=True)
class Subject:
    """The authenticated caller identity."""

    id: str


class TokenVerifier(Protocol):
    """Verifies an Authorization header and returns the caller's subject."""

    async def verify(self, authorization: str | None) -> Subject: ...


Decoder = Callable[[str], Awaitable[Mapping[str, Any]]]


class DevTokenVerifier:
    """Local verifier for the pre-account path.

    Accepts an explicit `dev:<subject>` token or a Firebase-shaped JWT, so the
    gateway enforces authentication before a Firebase project is wired.
    """

    async def verify(self, authorization: str | None) -> Subject:
        token = _extract_bearer(authorization)
        subject = _dev_subject(token)
        if subject is None:
            raise UnauthorizedError("The token is invalid.")
        return Subject(id=subject)


class FirebaseTokenVerifier:
    """Verifies Firebase ID tokens against the project's signing certificates."""

    def __init__(self, project_id: str, decoder: Decoder | None = None) -> None:
        self._project_id = project_id
        self._decoder = decoder if decoder is not None else _decoder_for(project_id)

    async def verify(self, authorization: str | None) -> Subject:
        token = _extract_bearer(authorization)
        try:
            claims = await self._decoder(token)
        except Exception as exc:
            raise UnauthorizedError("The token could not be verified.") from exc
        subject = claims.get("sub")
        if not isinstance(subject, str) or not subject:
            raise UnauthorizedError("The token has no subject.")
        return Subject(id=subject)


def build_token_verifier(settings: Settings) -> TokenVerifier:
    """Build the verifier the gateway uses for the configured auth mode."""

    if settings.auth_mode == "firebase":
        if not settings.firebase_project_id:
            raise ValueError("FIREBASE_PROJECT_ID is required when AUTH_MODE=firebase.")
        return FirebaseTokenVerifier(settings.firebase_project_id)
    return DevTokenVerifier()


def _extract_bearer(authorization: str | None) -> str:
    if not authorization:
        raise UnauthorizedError("The Authorization header is missing.")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise UnauthorizedError("A bearer token is required.")
    return token.strip()


def _dev_subject(token: str) -> str | None:
    prefix = "dev:"
    if token.startswith(prefix) and len(token) > len(prefix):
        return token[len(prefix) :]
    parts = token.split(".")
    if len(parts) == 3 and all(parts):
        return token
    return None


def _decoder_for(project_id: str) -> Decoder:
    async def decode(token: str) -> Mapping[str, Any]:
        return await _decode_firebase_token(project_id, token)

    return decode


async def _decode_firebase_token(project_id: str, token: str) -> Mapping[str, Any]:
    header = jwt.get_unverified_header(token)
    key_id = header.get("kid")
    if not isinstance(key_id, str) or not key_id:
        raise jwt.InvalidTokenError("The token header has no key id.")
    signing_key = await _signing_key_for(key_id)
    claims: dict[str, Any] = jwt.decode(
        token,
        key=signing_key,
        algorithms=["RS256"],
        audience=project_id,
        issuer=f"https://securetoken.google.com/{project_id}",
    )
    return claims


def _public_key_pem(certificate_pem: str) -> str:
    """Extract the public key from a Firebase signing certificate.

    The provider publishes X.509 certificates, but PyJWT's RSA algorithm expects
    a bare public key, so the certificate is parsed and its key re-encoded.
    """

    certificate = x509.load_pem_x509_certificate(certificate_pem.encode("utf-8"))
    return (
        certificate.public_key()
        .public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        .decode("utf-8")
    )


_signing_keys: dict[str, str] = {}
_signing_keys_expire_at = 0.0


async def _signing_key_for(key_id: str) -> str:
    global _signing_keys_expire_at

    now = time.monotonic()
    if key_id in _signing_keys and now < _signing_keys_expire_at:
        return _signing_keys[key_id]
    certificates = await _fetch_certificates()
    _signing_keys.clear()
    for kid, certificate in certificates.items():
        try:
            _signing_keys[kid] = _public_key_pem(certificate)
        except ValueError:
            # A certificate that cannot be parsed contributes no key; the
            # remaining certificates are still cached.
            continue
    _signing_keys_expire_at = now + _CERT_CACHE_TTL_SECONDS
    if key_id not in _signing_keys:
        raise jwt.InvalidTokenError("The token was signed with an unknown key.")
    return _signing_keys[key_id]


async def _fetch_certificates() -> Mapping[str, str]:
    async with httpx2.AsyncClient(timeout=10.0) as client:
        response = await client.get(_FIREBASE_CERTS_URL)
        response.raise_for_status()
        payload = response.json()
    if not isinstance(payload, dict):
        raise jwt.InvalidTokenError("The provider returned no certificates.")
    return {
        key: value
        for key, value in payload.items()
        if isinstance(key, str) and isinstance(value, str)
    }

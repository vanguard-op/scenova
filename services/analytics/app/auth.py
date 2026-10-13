"""Token verification for the event intake (C-007 auth).

The contract takes a Firebase ID token: anonymous before sign-in, upgraded to the
reader's account at sign-in (D-011). The intake resolves the pseudonymous
`user_id` from the token subject and never from the payload, so no client-supplied
identity is trusted. `DevTokenVerifier` is the local seam for the pre-account
path; `FirebaseTokenVerifier` verifies real ID tokens against the project's
signing certificates.
"""

from __future__ import annotations

import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any, Protocol

import httpx2
import jwt

from .config import Settings
from .errors import UnauthorizedError

_FIREBASE_CERTS_URL = (
    "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"
)
_CERT_CACHE_TTL_SECONDS = 3600.0


@dataclass(frozen=True)
class Subject:
    """The authenticated caller identity, used as the pseudonymous `user_id`."""

    id: str


class TokenVerifier(Protocol):
    """Verifies an Authorization header and returns the caller's subject."""

    async def verify(self, authorization: str | None) -> Subject: ...


Decoder = Callable[[str], Awaitable[Mapping[str, Any]]]


class DevTokenVerifier:
    """Local verifier for the pre-account path.

    Accepts an explicit `dev:<subject>` token or a Firebase-shaped JWT, so the
    intake enforces authentication before a Firebase project is wired.
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
    """Build the verifier the intake uses for the configured auth mode."""

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
    certificate = await _certificate_for(key_id)
    claims: dict[str, Any] = jwt.decode(
        token,
        key=certificate,
        algorithms=["RS256"],
        audience=project_id,
        issuer=f"https://securetoken.google.com/{project_id}",
    )
    return claims


_certificates: dict[str, str] = {}
_certificates_expire_at = 0.0


async def _certificate_for(key_id: str) -> str:
    global _certificates_expire_at

    now = time.monotonic()
    if key_id in _certificates and now < _certificates_expire_at:
        return _certificates[key_id]
    async with httpx2.AsyncClient(timeout=10.0) as client:
        response = await client.get(_FIREBASE_CERTS_URL)
        response.raise_for_status()
        payload = response.json()
    if not isinstance(payload, dict):
        raise jwt.InvalidTokenError("The provider returned no certificates.")
    _certificates.clear()
    for key, value in payload.items():
        if isinstance(key, str) and isinstance(value, str):
            _certificates[key] = value
    _certificates_expire_at = now + _CERT_CACHE_TTL_SECONDS
    if key_id not in _certificates:
        raise jwt.InvalidTokenError("The token was signed with an unknown key.")
    return _certificates[key_id]

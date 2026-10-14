"""Operator authentication for the curator review routes (C-014 to C-016 auth).

The review endpoints the console calls are operator-only: they take an
operator's Firebase ID token, require the `curator` custom claim, and require a
multi-factor session. The gateway refuses a caller with no session (401) and an
authenticated caller without the role or without a second factor (403), and logs
the attempt — never the token. The review service enforces the same rule behind
the gateway, so a directly-addressed instance is refused too.

`DevOperatorVerifier` is the local seam before a Firebase project is wired;
`FirebaseOperatorVerifier` verifies real ID tokens against the project's signing
certificates.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any, Protocol

from .auth import decode_firebase_id_token
from .config import Settings
from .errors import ForbiddenError, UnauthorizedError

logger = logging.getLogger(__name__)

# The custom claim `make curator` grants and this gate requires.
CURATOR_CLAIM = "curator"
# The ID-token claim Firebase sets when a session was multi-factor authenticated.
SECOND_FACTOR_CLAIM = "sign_in_second_factor"


@dataclass(frozen=True)
class OperatorSession:
    """An authenticated operator and the role signals the gate checked."""

    subject: str
    is_curator: bool
    mfa_verified: bool


class OperatorVerifier(Protocol):
    """Resolves an operator session, refusing a caller that may not review."""

    async def verify(self, authorization: str | None) -> OperatorSession: ...


ClaimsDecoder = Callable[[str], Awaitable[Mapping[str, Any]]]


class DevOperatorVerifier:
    """Local operator verifier for the pre-account path.

    Accepts `dev:curator:mfa:<subject>` for a curator session with a second
    factor, `dev:curator:<subject>` for the role without one, and
    `dev:<subject>` for a plain authenticated operator.
    """

    async def verify(self, authorization: str | None) -> OperatorSession:
        token = _extract_bearer(authorization)
        session = _dev_session(token)
        if session is None:
            logger.warning("review access refused: no operator session")
            raise UnauthorizedError("The operator session is missing or invalid.")
        _require_curator(session)
        return session


class FirebaseOperatorVerifier:
    """Verifies real operator ID tokens and checks the role and second factor."""

    def __init__(self, project_id: str, decoder: ClaimsDecoder | None = None) -> None:
        self._project_id = project_id
        self._decoder = decoder if decoder is not None else _decoder_for(project_id)

    async def verify(self, authorization: str | None) -> OperatorSession:
        token = _extract_bearer(authorization)
        try:
            claims = await self._decoder(token)
        except Exception as exc:
            logger.warning("review access refused: the operator token did not verify")
            raise UnauthorizedError("The operator session could not be verified.") from exc
        subject = claims.get("sub")
        if not isinstance(subject, str) or not subject:
            logger.warning("review access refused: the operator token has no subject")
            raise UnauthorizedError("The operator session has no subject.")
        session = OperatorSession(
            subject=subject,
            is_curator=bool(claims.get(CURATOR_CLAIM)),
            mfa_verified=_has_second_factor(claims),
        )
        _require_curator(session)
        return session


def build_operator_verifier(settings: Settings) -> OperatorVerifier:
    """Build the operator verifier for the configured auth mode."""

    if settings.auth_mode == "firebase":
        if not settings.firebase_project_id:
            raise ValueError("FIREBASE_PROJECT_ID is required when AUTH_MODE=firebase.")
        return FirebaseOperatorVerifier(settings.firebase_project_id)
    return DevOperatorVerifier()


def _require_curator(session: OperatorSession) -> None:
    if not session.is_curator:
        logger.warning(
            "review access refused for %s: the curator role is required", session.subject
        )
        raise ForbiddenError("The curator role is required.")
    if not session.mfa_verified:
        logger.warning(
            "review access refused for %s: a multi-factor session is required",
            session.subject,
        )
        raise ForbiddenError("A multi-factor session is required.")


def _has_second_factor(claims: Mapping[str, Any]) -> bool:
    firebase = claims.get("firebase")
    if not isinstance(firebase, Mapping):
        return False
    return bool(firebase.get(SECOND_FACTOR_CLAIM))


def _extract_bearer(authorization: str | None) -> str:
    if not authorization:
        raise UnauthorizedError("The Authorization header is missing.")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise UnauthorizedError("A bearer token is required.")
    return token.strip()


def _dev_session(token: str) -> OperatorSession | None:
    prefix = "dev:"
    if not token.startswith(prefix) or len(token) <= len(prefix):
        return None
    rest = token[len(prefix) :]
    if rest.startswith("curator:mfa:"):
        subject = rest[len("curator:mfa:") :]
        if subject:
            return OperatorSession(subject=subject, is_curator=True, mfa_verified=True)
        return None
    if rest.startswith("curator:"):
        subject = rest[len("curator:") :]
        if subject:
            return OperatorSession(subject=subject, is_curator=True, mfa_verified=False)
        return None
    return OperatorSession(subject=rest, is_curator=False, mfa_verified=False)


def _decoder_for(project_id: str) -> ClaimsDecoder:
    async def decode(token: str) -> Mapping[str, Any]:
        return await decode_firebase_id_token(project_id, token)

    return decode

"""Service-identity tokens for the gateway's calls to the internal services.

The gateway is the product's only public surface; every service behind it is
internal only and accepts a call only from an authenticated service identity
(architecture.md "Component: API Gateway"; nfr.md NFR-020). Cloud Run enforces
that identity at the platform edge, so the gateway mints a short-lived ID token
for its own runtime service account and presents it on
`X-Serverless-Authorization` — the header Cloud Run reads and strips before the
request reaches the container. The caller's own `Authorization` header is left
untouched, so the service behind the edge still decides it as its contract says:
a reader's Firebase token on the reader routes, and the payment processor's
webhook on the store billing sync.

The token is minted from the runtime service account through Application Default
Credentials, so no credential is stored (NFR-024). Outside a deployed service
there is no platform edge to satisfy, so the identity stands down and the local
stack and the unit tests call the services directly.
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Callable

import google.auth.exceptions
import google.auth.transport.requests
from google.oauth2 import id_token as google_id_token

logger = logging.getLogger(__name__)

# The header Cloud Run reads the caller's identity from, then strips, so an
# `Authorization` header meant for the service behind the edge survives.
SERVERLESS_AUTHORIZATION_HEADER = "x-serverless-authorization"

# Cloud Run sets K_SERVICE on every instance it starts; its absence means the
# process is not behind the platform edge and has no identity to assert.
_CLOUD_RUN_SERVICE_ENV = "K_SERVICE"

# An ID token lives an hour; re-mint well inside that so a token never expires
# between the mint and the call it authorizes.
_TOKEN_TTL_SECONDS = 2400.0


class ServiceIdentity:
    """Mints and caches the gateway's own ID token for one internal service.

    One instance is held per downstream service, because Cloud Run binds the ID
    token's audience to the service being called. The mint is lazy and cached, so
    an instance costs one metadata call an hour rather than one per request.
    """

    def __init__(
        self,
        audience: str,
        *,
        enabled: bool | None = None,
        fetch: Callable[[str], str] | None = None,
        clock: Callable[[], float] = time.monotonic,
        ttl_seconds: float = _TOKEN_TTL_SECONDS,
    ) -> None:
        self._audience = audience.rstrip("/")
        self._enabled = bool(os.environ.get(_CLOUD_RUN_SERVICE_ENV)) if enabled is None else enabled
        self._fetch = fetch or _fetch_id_token
        self._clock = clock
        self._ttl = ttl_seconds
        self._token: str | None = None
        self._expires_at = 0.0

    def headers(self) -> dict[str, str]:
        """The identity header for a call, or none where there is no edge to satisfy."""

        if not self._enabled:
            return {}
        token = self._current_token()
        if token is None:
            return {}
        return {SERVERLESS_AUTHORIZATION_HEADER: f"Bearer {token}"}

    def _current_token(self) -> str | None:
        now = self._clock()
        if self._token is not None and now < self._expires_at:
            return self._token
        try:
            token = self._fetch(self._audience)
        except (google.auth.exceptions.GoogleAuthError, ValueError) as exc:
            # A metadata outage must not fail the call outright: the service
            # behind the edge refuses an unauthenticated call, which is the
            # honest answer, rather than the gateway inventing one.
            logger.warning("could not mint the service identity token: %s", exc)
            return None
        self._token = token
        self._expires_at = now + self._ttl
        return token


def _fetch_id_token(audience: str) -> str:
    # google-auth leaves `fetch_id_token` unannotated.
    token = google_id_token.fetch_id_token(  # type: ignore[no-untyped-call]
        google.auth.transport.requests.Request(), audience
    )
    return str(token)

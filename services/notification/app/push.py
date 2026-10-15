"""Push delivery for a finished clip (architecture "Notification Service").

The service consumes a push notification service. A send either reaches the
provider or raises `PushUnavailableError`, which the service turns into a queued
notice so a provider outage delays a notice rather than losing it.

The platform's configured provider is Firebase Cloud Messaging, reached through
its HTTP v1 send endpoint and authorized by a short-lived OAuth 2.0 token minted
from Application Default Credentials, so no credential is carried in config
(NFR-024). A generic HTTP seam stands in for a test double or a non-Firebase
deployment, and a logging seam keeps the service bootable with no provider.

The notice carries the lookup and the clip, never the word or phrase: the
reader's selection is never handed to the push provider, and the notice text
stays generic so it reads the same on a lock screen to anyone nearby.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Protocol

import google.auth
import google.auth.exceptions
import httpx2
from google.auth.credentials import Credentials
from google.auth.transport.requests import Request

from .models import Platform

logger = logging.getLogger(__name__)

# The generic copy a notice shows. It is deliberately word-free: the reader's
# selection is theirs, and it is never carried to the provider or shown where
# someone else might read it.
NOTICE_TITLE = "Your clip is ready"
NOTICE_BODY = "Open Scenova to watch it."

# The OAuth 2.0 scope a Firebase Cloud Messaging send requires.
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


@dataclass(frozen=True)
class ClipReadyNotice:
    """A finished clip the reader is to be told about.

    `token` is deliberately not a field: the notice is the message, and the
    token is supplied per send so it is never held in the queued payload.
    `job_id` is the finished job the ingest named; a notice rebuilt from the
    queue after a restart carries none, because the queued payload is the
    lookup and the clip (schema "PendingNotice").
    """

    lookup_id: str
    clip_url: str
    duration_seconds: float
    resolution: str
    has_audio: bool
    job_id: str = ""


class PushUnavailableError(Exception):
    """The push provider could not be reached; the notice is queued, not lost."""


class PushSender(Protocol):
    """Sends a clip-ready notice to one device."""

    async def send(self, *, token: str, platform: Platform, notice: ClipReadyNotice) -> None: ...

    async def aclose(self) -> None: ...


class LoggingPushSender:
    """A placeholder sender that records the notice without a payload.

    The push provider is wired later, so the default seam logs that a notice was
    sent. It never logs the push token.
    """

    async def send(self, *, token: str, platform: Platform, notice: ClipReadyNotice) -> None:
        logger.info(
            "sent a clip-ready notice for lookup %s on %s",
            notice.lookup_id,
            platform.value,
        )

    async def aclose(self) -> None:
        return None


class HttpPushSender:
    """Calls the push provider over HTTP."""

    def __init__(
        self,
        *,
        base_url: str,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def send(self, *, token: str, platform: Platform, notice: ClipReadyNotice) -> None:
        payload = {
            "token": token,
            "platform": platform.value,
            "notification": {
                "title": NOTICE_TITLE,
                "body": NOTICE_BODY,
                "data": {
                    "lookupId": notice.lookup_id,
                    "clipUrl": notice.clip_url,
                    "durationSeconds": notice.duration_seconds,
                    "resolution": notice.resolution,
                    "hasAudio": notice.has_audio,
                },
            },
        }
        try:
            response = await self._client.post("/v1/notifications", json=payload)
        except httpx2.HTTPError as exc:
            raise PushUnavailableError("The push provider is unreachable.") from exc
        if response.status_code >= 500:
            raise PushUnavailableError("The push provider could not accept the notice.")
        if response.status_code >= 400:
            # A refused token is not deliverable and will not become deliverable
            # by retrying, so it is dropped rather than queued forever.
            logger.warning("the push provider refused a notice for lookup %s", notice.lookup_id)

    async def aclose(self) -> None:
        await self._client.aclose()


class TokenProvider(Protocol):
    """Mints an access token for the push provider.

    A refresh is a blocking network call, so the sender performs it off the
    event loop. The token is held in memory only, never written to the
    environment or a file (NFR-024).
    """

    def token(self) -> str: ...


class AdcTokenProvider:
    """Mints a short-lived access token from Application Default Credentials.

    In the cloud the runtime service account is granted the Firebase Cloud
    Messaging send role and no other service is, so the token is scoped to the
    send and nothing broader. A credential that cannot be minted is reported as
    `PushUnavailableError`, so the notice is queued rather than dropped.
    """

    def __init__(self, *, scopes: tuple[str, ...] = (FCM_SCOPE,)) -> None:
        self._scopes = scopes
        self._credentials: Credentials | None = None
        self._request = Request()

    def token(self) -> str:
        try:
            credentials = self._credentials
            if credentials is None:
                credentials, _ = google.auth.default(scopes=list(self._scopes))
                self._credentials = credentials
            if not credentials.valid:
                # google-auth leaves `Credentials.refresh` unannotated.
                credentials.refresh(self._request)  # type: ignore[no-untyped-call]
            access_token: str | None = credentials.token
        except google.auth.exceptions.GoogleAuthError as exc:
            raise PushUnavailableError("No push credential could be minted.") from exc
        if not access_token:
            raise PushUnavailableError("No push credential could be minted.")
        return access_token


class FcmPushSender:
    """Sends a notice through Firebase Cloud Messaging (HTTP v1).

    The send is a POST to the target project's `messages:send` endpoint,
    authorized by a short-lived OAuth 2.0 bearer token from Application Default
    Credentials. A provider that is unreachable, throttles, or refuses the
    credential raises `PushUnavailableError` so the notice is queued and retried;
    a token the provider rejects as malformed or unregistered is dropped, since
    retrying will never register it. The reader's selection is never in the
    message, only the lookup and the clip.
    """

    def __init__(
        self,
        *,
        base_url: str,
        project_id: str | None,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        token_provider: TokenProvider | None = None,
    ) -> None:
        self._project_id = project_id
        self._tokens = token_provider or AdcTokenProvider()
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def send(self, *, token: str, platform: Platform, notice: ClipReadyNotice) -> None:
        if not self._project_id:
            raise PushUnavailableError("The push provider has no Firebase project configured.")
        access_token = await asyncio.to_thread(self._tokens.token)
        payload = {
            "message": {
                "token": token,
                "notification": {"title": NOTICE_TITLE, "body": NOTICE_BODY},
                # FCM carries data values as strings.
                "data": {
                    "lookupId": notice.lookup_id,
                    "clipUrl": notice.clip_url,
                    "durationSeconds": str(notice.duration_seconds),
                    "resolution": notice.resolution,
                    "hasAudio": "true" if notice.has_audio else "false",
                },
            }
        }
        try:
            response = await self._client.post(
                f"/v1/projects/{self._project_id}/messages:send",
                headers={"Authorization": f"Bearer {access_token}"},
                json=payload,
            )
        except httpx2.HTTPError as exc:
            raise PushUnavailableError("The push provider is unreachable.") from exc
        if response.status_code >= 500 or response.status_code == 429:
            raise PushUnavailableError("The push provider could not accept the notice.")
        if response.status_code in {401, 403}:
            # The credential was refused; a re-minted token may be accepted, so
            # this is treated as retryable rather than dropped.
            raise PushUnavailableError("The push provider refused the credential.")
        if response.status_code >= 400:
            logger.warning(
                "the push provider refused a notice for lookup %s (status %s)",
                notice.lookup_id,
                response.status_code,
            )

    async def aclose(self) -> None:
        await self._client.aclose()

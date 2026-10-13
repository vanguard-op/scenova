"""Push delivery for a finished clip (architecture "Notification Service").

The service consumes a push notification service. A send either reaches the
provider or raises `PushUnavailableError`, which the service turns into a queued
notice so a provider outage delays a notice rather than losing it.

The notice carries the lookup and the clip, never the word or phrase: the
reader's selection is never handed to the push provider, and the notice text
stays generic so it reads the same on a lock screen to anyone nearby.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

import httpx2

from .models import Platform

logger = logging.getLogger(__name__)

# The generic copy a notice shows. It is deliberately word-free: the reader's
# selection is theirs, and it is never carried to the provider or shown where
# someone else might read it.
NOTICE_TITLE = "Your clip is ready"
NOTICE_BODY = "Open Scenova to watch it."


@dataclass(frozen=True)
class ClipReadyNotice:
    """A finished clip the reader is to be told about.

    `token` is deliberately not a field: the notice is the message, and the
    token is supplied per send so it is never held in the queued payload.
    """

    lookup_id: str
    job_id: str
    clip_url: str
    duration_seconds: float
    resolution: str
    has_audio: bool


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

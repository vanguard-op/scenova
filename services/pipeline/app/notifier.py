"""Notification port for a finished clip (FEAT-008).

When a clip finishes after the reader's wait, the pipeline tells the notification
service so the reader can be told it is ready (architecture "Notification
Service": `Gen --> Notify`). The notice carries the identifiers and the clip the
shared library already holds, never the word or phrase, so nothing about the
reader's selection reaches the push provider.

The notice is a secondary effect of a generation that has already produced a
clip: if the notification service cannot be reached, the clip has still reached
the reader, so the failure is logged and dropped rather than raised. Raising here
would turn a completed generation into a failed job and misreport the generation
failure rate.
"""

from __future__ import annotations

import logging
from typing import Protocol

import httpx2

from .clip_client import ClipResult
from .service_identity import ServiceIdentity

logger = logging.getLogger(__name__)


class Notifier(Protocol):
    """Port for telling the reader a clip is ready."""

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None: ...

    async def aclose(self) -> None: ...


class LoggingNotifier:
    """A placeholder notifier that records the ready event without a payload.

    Used when no notification service is configured, so the pipeline still boots
    and a finished clip is observable. It never logs the word or phrase.
    """

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None:
        logger.info("clip ready for lookup %s (job %s)", lookup_id, job_id)

    async def aclose(self) -> None:
        return None


class HttpNotifier:
    """Reports a finished clip to the notification service (internal call).

    The call is best-effort: an unreachable or refusing notification service
    leaves the clip delivered and only the notice unrecorded, so it is logged and
    the job's success is unaffected.
    """

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The notification service is internal only, so Cloud Run checks the
        # caller's identity at the platform edge (nfr.md NFR-020). The audience
        # is this client's own base URL: Cloud Run binds the ID token to the
        # service being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None:
        payload = {
            "lookupId": lookup_id,
            "jobId": job_id,
            "clip": {
                "clipId": clip.clip_id,
                "storageKey": clip.storage_key,
                "url": clip.url,
                "durationSeconds": clip.duration_seconds,
                "resolution": clip.resolution,
                "hasAudio": clip.has_audio,
                "synthIdWatermark": clip.synth_id_watermark,
            },
        }
        try:
            response = await self._client.post(
                "/internal/clip-ready",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                json=payload,
            )
        except httpx2.HTTPError:
            logger.warning(
                "the notification service was unreachable; no clip-ready notice "
                "went out for lookup %s",
                lookup_id,
            )
            return
        if response.status_code // 100 != 2:
            logger.warning(
                "the notification service refused a clip-ready notice for lookup %s (status %s)",
                lookup_id,
                response.status_code,
            )

    async def aclose(self) -> None:
        await self._client.aclose()

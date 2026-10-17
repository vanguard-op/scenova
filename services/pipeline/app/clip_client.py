"""Client for the model-serving clip endpoint (C-005, FEAT-005).

The pipeline asks the model layer for a clip from a gloss phrase. A decline, a
timeout, and an unavailable provider are the reader's fallback, so each maps to
its own error the service turns into a job outcome rather than a clip.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol

import httpx2
from pydantic import BaseModel, ConfigDict

from .service_identity import ServiceIdentity


@dataclass(frozen=True)
class ClipResult:
    """A generated clip as returned by C-005."""

    clip_id: str
    storage_key: str
    url: str
    duration_seconds: float
    resolution: Literal["360p"]
    has_audio: bool
    synth_id_watermark: bool


class ClipGenerationError(Exception):
    """Base class for a clip-generation failure the pipeline maps to a fallback."""


class ClipDeclinedError(ClipGenerationError):
    """The provider declined the phrase (C-005 422); no clip was produced."""


class ClipTimeoutError(ClipGenerationError):
    """The provider timed out (C-005 504)."""


class ClipUnavailableError(ClipGenerationError):
    """The provider or the model service was unavailable (C-005 503)."""


class ClipGenerator(Protocol):
    """Port for the model-serving clip endpoint."""

    async def generate(
        self, *, phrase: str, target_duration_seconds: float, model_pin: str
    ) -> ClipResult: ...

    async def aclose(self) -> None: ...


class ClipResponseBody(BaseModel):
    """The C-005 201 response body."""

    model_config = ConfigDict(extra="forbid")

    clipId: str
    storageKey: str
    url: str
    durationSeconds: float
    resolution: Literal["360p"]
    hasAudio: bool
    synthIdWatermark: bool


class HttpClipClient:
    """Calls the model-serving clip endpoint over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        timeout_seconds: float = 120.0,
        transport: httpx2.AsyncBaseTransport | None = None,
        identity: ServiceIdentity | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        # The model-serving layer is internal only, so Cloud Run checks the
        # caller's identity at the platform edge (nfr.md NFR-020). The audience
        # is this client's own base URL: Cloud Run binds the ID token to the
        # service being called.
        self._identity = identity or ServiceIdentity(base_url)
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def generate(
        self, *, phrase: str, target_duration_seconds: float, model_pin: str
    ) -> ClipResult:
        try:
            response = await self._client.post(
                "/internal/model/clip",
                headers={
                    "x-internal-audience": self._internal_audience,
                    **self._identity.headers(),
                },
                json={
                    "phrase": phrase,
                    "targetDurationSeconds": target_duration_seconds,
                    "modelPin": model_pin,
                },
            )
        except httpx2.HTTPError as exc:
            raise ClipUnavailableError("The model service is unavailable.") from exc

        if response.status_code == 422:
            raise ClipDeclinedError("The provider declined the phrase.")
        if response.status_code == 504:
            raise ClipTimeoutError("The provider timed out.")
        if response.status_code != 201:
            raise ClipUnavailableError("The model service returned no clip.")

        try:
            body = ClipResponseBody.model_validate(response.json())
        except ValueError as exc:
            raise ClipUnavailableError("The model service returned an unusable clip.") from exc
        return ClipResult(
            clip_id=body.clipId,
            storage_key=body.storageKey,
            url=body.url,
            duration_seconds=body.durationSeconds,
            resolution=body.resolution,
            has_audio=body.hasAudio,
            synth_id_watermark=body.synthIdWatermark,
        )

    async def aclose(self) -> None:
        await self._client.aclose()

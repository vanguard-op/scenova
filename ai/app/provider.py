"""External model-provider integration for gloss-phrase and clip generation.

The provider is wrapped so the rest of the layer sees only three failure modes,
which map straight onto the capability contracts (C-004, C-005):

- `ProviderRefusal`   — the provider declined or produced nothing usable
- `ProviderTimeout`   — the provider did not answer inside the timeout
- `ProviderUnavailable` — the provider could not be reached after retries

Refusal and timeout are handled by the caller: the phrase path returns a
fallback (HTTP 200 with `source=fallback`) and the clip path returns 422 or 504,
both of which the pipeline maps to the reader's fallback. Unavailability after
retries is surfaced as HTTP 503.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Protocol, runtime_checkable

import httpx
from google import genai
from google.genai import errors as genai_errors
from google.genai import types as genai_types

from .config import Settings
from .resilience import CircuitBreaker

logger = logging.getLogger(__name__)


class ProviderError(Exception):
    """Base class for a model-provider failure."""


class ProviderRefusal(ProviderError):
    """The provider declined the input or returned no usable text."""


class ProviderTimeout(ProviderError):
    """The provider did not answer within the request timeout."""


class ProviderUnavailable(ProviderError):
    """The provider could not be reached after the configured retries."""


@runtime_checkable
class PhraseModel(Protocol):
    """The model call the phrase service depends on (injected for tests)."""

    async def generate(self, *, system: str, user: str, model_pin: str) -> str: ...


@runtime_checkable
class ClipModel(Protocol):
    """The model call the clip service depends on (injected for tests)."""

    async def generate(
        self,
        *,
        system: str,
        user: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> bytes: ...


def _extract_text(response: object) -> str:
    """Return the response text, or treat an empty/blocked response as a refusal."""

    text = getattr(response, "text", None)
    if isinstance(text, str) and text.strip():
        return text
    raise ProviderRefusal("model provider returned no usable text")


class GeminiPhraseModel:
    """Calls the Gemini API against the pinned model version."""

    def __init__(self, settings: Settings, *, breaker: CircuitBreaker | None = None) -> None:
        self._settings = settings
        self._breaker = breaker or CircuitBreaker(
            failure_threshold=settings.circuit_failure_threshold,
            reset_seconds=settings.circuit_reset_seconds,
        )
        self._client: genai.Client | None = None

    def _get_client(self) -> genai.Client:
        if self._client is None:
            if not self._settings.gemini_api_key:
                raise ProviderUnavailable("model provider credentials are not configured")
            self._client = genai.Client(api_key=self._settings.gemini_api_key)
        return self._client

    async def generate(self, *, system: str, user: str, model_pin: str) -> str:
        if not self._breaker.allow():
            raise ProviderUnavailable("model provider circuit is open")

        last_error: ProviderUnavailable | None = None
        for attempt in range(1, self._settings.max_attempts + 1):
            try:
                text = await self._call(system=system, user=user, model_pin=model_pin)
            except ProviderTimeout:
                # A slow provider is a fallback, not a retry (bounded latency).
                raise
            except ProviderUnavailable as exc:
                last_error = exc
                logger.warning(
                    "model provider call failed (attempt %d/%d)",
                    attempt,
                    self._settings.max_attempts,
                )
                if attempt < self._settings.max_attempts:
                    await asyncio.sleep(self._settings.retry_backoff_seconds * attempt)
                    continue
            else:
                self._breaker.record_success()
                return text

        self._breaker.record_failure()
        raise last_error or ProviderUnavailable("model provider unavailable")

    async def _call(self, *, system: str, user: str, model_pin: str) -> str:
        try:
            client = self._get_client()
            response: Any = await asyncio.wait_for(
                client.aio.models.generate_content(
                    model=model_pin,
                    contents=user,
                    config=genai_types.GenerateContentConfig(
                        system_instruction=system,
                        temperature=self._settings.temperature,
                        top_p=self._settings.top_p,
                        max_output_tokens=self._settings.max_output_tokens,
                    ),
                ),
                timeout=self._settings.request_timeout_seconds,
            )
        except TimeoutError as exc:
            raise ProviderTimeout("model provider timed out") from exc
        except (httpx.HTTPError, genai_errors.APIError, OSError) as exc:
            raise ProviderUnavailable(f"model provider request failed: {exc}") from exc
        return _extract_text(response)


def _combine_prompt(*, system: str, user: str) -> str:
    """Fold the system direction into the prompt for the video model.

    Video generation takes a single prompt rather than a system instruction, so
    the versioned artifact's system text is carried as the prompt's direction.
    """

    return f"{system}\n\n{user}"


def _extract_video(operation: Any) -> bytes:
    """Return the clip bytes, or treat a declined/empty result as a refusal."""

    error = getattr(operation, "error", None)
    if error:
        raise ProviderUnavailable(f"model provider operation failed: {error}")

    response = getattr(operation, "response", None)
    filtered = getattr(response, "rai_media_filtered_count", None)
    if isinstance(filtered, int) and filtered > 0:
        raise ProviderRefusal("model provider filtered the generated video")

    videos = getattr(response, "generated_videos", None) or []
    if not videos:
        raise ProviderRefusal("model provider returned no video")

    data = getattr(getattr(videos[0], "video", None), "video_bytes", None)
    if not data:
        raise ProviderRefusal("model provider returned no usable video data")
    return bytes(data)


class GeminiClipModel:
    """Generates a short clip through the Gemini API against the pinned version."""

    def __init__(self, settings: Settings, *, breaker: CircuitBreaker | None = None) -> None:
        self._settings = settings
        self._breaker = breaker or CircuitBreaker(
            failure_threshold=settings.circuit_failure_threshold,
            reset_seconds=settings.circuit_reset_seconds,
        )
        self._client: genai.Client | None = None

    def _get_client(self) -> genai.Client:
        if self._client is None:
            if not self._settings.gemini_api_key:
                raise ProviderUnavailable("model provider credentials are not configured")
            self._client = genai.Client(api_key=self._settings.gemini_api_key)
        return self._client

    async def generate(
        self,
        *,
        system: str,
        user: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> bytes:
        if not self._breaker.allow():
            raise ProviderUnavailable("model provider circuit is open")

        last_error: ProviderUnavailable | None = None
        for attempt in range(1, self._settings.max_attempts + 1):
            try:
                data = await self._call(
                    system=system,
                    user=user,
                    model_pin=model_pin,
                    duration_seconds=duration_seconds,
                    resolution=resolution,
                    generate_audio=generate_audio,
                )
            except (ProviderTimeout, ProviderRefusal):
                # A slow or declining provider will not improve on a retry.
                raise
            except ProviderUnavailable as exc:
                last_error = exc
                logger.warning(
                    "model provider clip call failed (attempt %d/%d)",
                    attempt,
                    self._settings.max_attempts,
                )
                if attempt < self._settings.max_attempts:
                    await asyncio.sleep(self._settings.retry_backoff_seconds * attempt)
                    continue
            else:
                self._breaker.record_success()
                return data

        self._breaker.record_failure()
        raise last_error or ProviderUnavailable("model provider unavailable")

    async def _call(
        self,
        *,
        system: str,
        user: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> bytes:
        try:
            client = self._get_client()
            operation: Any = await asyncio.wait_for(
                self._generate(
                    client,
                    prompt=_combine_prompt(system=system, user=user),
                    model_pin=model_pin,
                    duration_seconds=duration_seconds,
                    resolution=resolution,
                    generate_audio=generate_audio,
                ),
                timeout=self._settings.clip_video_timeout_seconds,
            )
        except TimeoutError as exc:
            raise ProviderTimeout("model provider timed out") from exc
        except (httpx.HTTPError, genai_errors.APIError, OSError) as exc:
            raise ProviderUnavailable(f"model provider request failed: {exc}") from exc
        return _extract_video(operation)

    async def _generate(
        self,
        client: genai.Client,
        *,
        prompt: str,
        model_pin: str,
        duration_seconds: int,
        resolution: str,
        generate_audio: bool,
    ) -> Any:
        """Submit the video job and poll the long-running operation to completion."""

        operation: Any = await client.aio.models.generate_videos(
            model=model_pin,
            prompt=prompt,
            config=genai_types.GenerateVideosConfig(
                number_of_videos=1,
                duration_seconds=duration_seconds,
                resolution=resolution,
                generate_audio=generate_audio,
            ),
        )
        while not getattr(operation, "done", False):
            await asyncio.sleep(self._settings.clip_poll_interval_seconds)
            operation = await client.aio.operations.get(operation)
        return operation

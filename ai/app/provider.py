"""External model-provider integration for gloss-phrase generation (FEAT-004).

The provider is wrapped so the rest of the layer sees only three failure modes,
which map straight onto the capability contract (C-004):

- `ProviderRefusal`   — the provider declined or produced nothing usable
- `ProviderTimeout`   — the provider did not answer inside the timeout
- `ProviderUnavailable` — the provider could not be reached after retries

Refusal and timeout are handled by the caller as a fallback (HTTP 200 with
`source=fallback`); unavailability after retries is surfaced as HTTP 503.
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
